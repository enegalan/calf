package runtime

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sort"
	"strings"
)

type networkLine struct {
	ID     string `json:"ID"`
	Name   string `json:"Name"`
	Driver string `json:"Driver"`
}

type networkInspectRow struct {
	ID      string            `json:"Id"`
	Name    string            `json:"Name"`
	Created string            `json:"Created"`
	Scope   string            `json:"Scope"`
	Driver  string            `json:"Driver"`
	IPAM    networkIPAM       `json:"IPAM"`
	Options map[string]string `json:"Options"`
	Labels  map[string]string `json:"Labels"`
}

type networkIPAM struct {
	Config []networkIPAMConfig `json:"Config"`
}

type networkIPAMConfig struct {
	Subnet  string `json:"Subnet"`
	Gateway string `json:"Gateway"`
}

type nativeNetworkInspect struct {
	CNI nativeNetworkCNI `json:"CNI"`
}

type nativeNetworkCNI struct {
	Name    string            `json:"name"`
	Plugins []nativeCNIPlugin `json:"plugins"`
}

type nativeCNIPlugin struct {
	Type        string        `json:"type"`
	Bridge      string        `json:"bridge"`
	IsGateway   bool          `json:"isGateway"`
	IPMasq      bool          `json:"ipMasq"`
	HairpinMode bool          `json:"hairpinMode"`
	MTU         int           `json:"mtu"`
	IPAM        nativeCNIIPAM `json:"ipam"`
}

type nativeCNIIPAM struct {
	Ranges [][][]nativeCNIIPAMRange `json:"ranges"`
}

type nativeCNIIPAMRange struct {
	Subnet  string `json:"subnet"`
	Gateway string `json:"gateway"`
}

// isPseudoNetwork reports whether name is a built-in pseudo network (host, none, or null).
func isPseudoNetwork(name string) bool {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "host", "none", "null":
		return true
	default:
		return false
	}
}

// IsPseudoNetwork reports whether name refers to a built-in Docker pseudo network.
func IsPseudoNetwork(name string) bool {
	return isPseudoNetwork(name)
}

// listNetworks returns all user-defined networks, enriching list output with inspect metadata when available.
func listNetworks(ctx context.Context, run commandRunner) ([]Network, error) {
	networks, nerdctlErr := queryNerdctlNetworks(ctx, run)
	if nerdctlErr != nil {
		dockerNetworks, dockerErr := queryDockerNetworks(ctx, run)
		if dockerErr != nil {
			return nil, nerdctlErr
		}

		networks = dockerNetworks
	} else {
		dockerExtra, err := queryDockerNetworks(ctx, run)
		if err == nil {
			networks = mergeNetworksByName(networks, dockerExtra)
		}
	}

	if len(networks) == 0 {
		return networks, nil
	}

	names := make([]string, 0, len(networks))
	for _, network := range networks {
		names = append(names, network.Name)
	}

	metadata, err := networkInspectMetadataBatch(ctx, run, names)
	if err != nil {
		return networks, nil
	}

	for index := range networks {
		row, ok := metadata[networks[index].Name]
		if !ok {
			if networks[index].Scope == "" {
				networks[index].Scope = defaultNetworkScope()
			}
			continue
		}

		networks[index].ID = shortNetworkID(firstNonEmpty(row.ID, networks[index].ID))
		driver := strings.TrimSpace(row.Driver)
		if driver == "" {
			driver = row.NativeDriver
		}
		if driver != "" {
			networks[index].Driver = driver
		}
		if scope := strings.TrimSpace(row.Scope); scope != "" {
			networks[index].Scope = scope
		} else {
			networks[index].Scope = defaultNetworkScope()
		}
		networks[index].Subnet = firstSubnet(row)
		if networks[index].Subnet == "" {
			networks[index].Subnet = row.NativeSubnet
		}
		if created := humanizeTime(row.Created); created != "" {
			networks[index].Created = created
		}
	}

	return networks, nil
}

// inspectNetwork returns detailed metadata for a single network by name.
func inspectNetwork(ctx context.Context, run commandRunner, name string) (NetworkDetail, error) {
	if isPseudoNetwork(name) {
		return NetworkDetail{}, fmt.Errorf("built-in network %q cannot be inspected", name)
	}

	driver, _ := networkDriverFromList(ctx, run, name)

	row, err := inspectNetworkMetadata(ctx, run, name)
	if err != nil {
		return NetworkDetail{}, err
	}

	if driver == "" {
		driver = strings.TrimSpace(row.Driver)
	}
	if driver == "" {
		driver = row.NativeDriver
	}

	scope := strings.TrimSpace(row.Scope)
	if scope == "" {
		scope = defaultNetworkScope()
	}

	subnet := firstSubnet(row)
	gateway := firstGateway(row)
	if subnet == "" {
		subnet = row.NativeSubnet
	}
	if gateway == "" {
		gateway = row.NativeGateway
	}

	options := make(map[string]string, len(row.Options)+len(row.NativeOptions))
	for key, value := range row.Options {
		options[key] = value
	}
	for key, value := range row.NativeOptions {
		options[key] = value
	}

	return NetworkDetail{
		ID:      shortNetworkID(row.ID),
		Name:    row.Name,
		Driver:  driver,
		Scope:   scope,
		Subnet:  subnet,
		Gateway: gateway,
		Created: humanizeNetworkCreated(row.Created),
		Options: options,
	}, nil
}

// removeNetwork deletes a user-defined network via nerdctl, falling back to docker.
func removeNetwork(ctx context.Context, run commandRunner, name string) error {
	if isPseudoNetwork(name) {
		return fmt.Errorf("built-in network %q cannot be removed", name)
	}

	_, err := run(ctx, "nerdctl", "network", "rm", name)
	if err != nil {
		_, err = run(ctx, "docker", "network", "rm", name)
	}
	return err
}

type enrichedNetworkInspectRow struct {
	networkInspectRow
	NativeDriver  string
	NativeSubnet  string
	NativeGateway string
	NativeOptions map[string]string
}

// inspectNetworkMetadata fetches standard and native inspect data for one network.
func inspectNetworkMetadata(ctx context.Context, run commandRunner, name string) (enrichedNetworkInspectRow, error) {
	row := enrichedNetworkInspectRow{
		NativeOptions: make(map[string]string),
	}

	args := []string{"network", "inspect", name}
	output, err := run(ctx, "nerdctl", args...)
	if err != nil {
		output, err = run(ctx, "docker", args...)
		if err != nil {
			return row, err
		}
	}

	parsed, err := decodeInspectDocuments[networkInspectRow](output)
	if err != nil {
		return row, err
	}

	if len(parsed) == 0 {
		return row, fmt.Errorf("inspect network %s", name)
	}

	row.networkInspectRow = parsed[0]
	if row.Name == "" {
		row.Name = name
	}

	nativeOutput, nativeErr := run(ctx, "nerdctl", "network", "inspect", "--mode=native", name)
	if nativeErr == nil {
		applyNativeNetworkInspect(&row, nativeOutput)
	}

	return row, nil
}

// networkInspectMetadataBatch inspects multiple networks, skipping pseudo networks and individual failures.
func networkInspectMetadataBatch(ctx context.Context, run commandRunner, names []string) (map[string]enrichedNetworkInspectRow, error) {
	rows := make(map[string]enrichedNetworkInspectRow, len(names))
	for _, name := range names {
		if isPseudoNetwork(name) {
			continue
		}

		row, err := inspectNetworkMetadata(ctx, run, name)
		if err != nil {
			slog.Warn("failed to inspect network metadata", "network", name, "error", err)
			continue
		}

		rows[name] = row
	}

	return rows, nil
}

// networkDriverFromList looks up a network's driver from nerdctl or docker list output.
func networkDriverFromList(ctx context.Context, run commandRunner, name string) (string, error) {
	networks, err := queryNerdctlNetworks(ctx, run)
	if err != nil {
		return "", err
	}

	for _, network := range networks {
		if network.Name == name {
			return network.Driver, nil
		}
	}

	dockerNetworks, err := queryDockerNetworks(ctx, run)
	if err != nil {
		return "", fmt.Errorf("network %s not found", name)
	}

	for _, network := range dockerNetworks {
		if network.Name == name {
			return network.Driver, nil
		}
	}

	return "", fmt.Errorf("network %s not found", name)
}

// applyNativeNetworkInspect merges CNI plugin details from native-mode inspect into row.
func applyNativeNetworkInspect(row *enrichedNetworkInspectRow, output []byte) {
	parsed, err := decodeInspectDocuments[nativeNetworkInspect](output)
	if err != nil || len(parsed) == 0 {
		return
	}

	native := parsed[0]
	for _, plugin := range native.CNI.Plugins {
		pluginType := strings.TrimSpace(plugin.Type)
		if row.NativeDriver == "" && pluginType != "" && pluginType != "portmap" && pluginType != "firewall" && pluginType != "tuning" {
			row.NativeDriver = pluginType
		}

		for _, rangeGroup := range plugin.IPAM.Ranges {
			for _, ipamRanges := range rangeGroup {
				for _, ipamRange := range ipamRanges {
					if row.NativeSubnet == "" && strings.TrimSpace(ipamRange.Subnet) != "" {
						row.NativeSubnet = strings.TrimSpace(ipamRange.Subnet)
					}
					if row.NativeGateway == "" && strings.TrimSpace(ipamRange.Gateway) != "" {
						row.NativeGateway = strings.TrimSpace(ipamRange.Gateway)
					}
				}
			}
		}

		if bridge := strings.TrimSpace(plugin.Bridge); bridge != "" {
			row.NativeOptions["com.docker.network.bridge.name"] = bridge
		}
		if plugin.MTU > 0 {
			row.NativeOptions["com.docker.network.driver.mtu"] = fmt.Sprintf("%d", plugin.MTU)
		}
		if plugin.IPMasq {
			row.NativeOptions["com.docker.network.bridge.enable_ip_masquerade"] = "true"
		}
		if plugin.HairpinMode {
			row.NativeOptions["com.docker.network.bridge.enable_hairpin_mode"] = "true"
		}
		if plugin.IsGateway {
			row.NativeOptions["com.docker.network.bridge.enable_icc"] = "true"
		}
	}

	if row.Name == "bridge" {
		row.NativeOptions["com.docker.network.bridge.default_bridge"] = "true"
	}
}

// ParseNetworkLines decodes newline-delimited JSON network list output into sorted Network values.
func ParseNetworkLines(output []byte) ([]Network, error) {
	networks := make([]Network, 0)
	scanner := bufio.NewScanner(bytes.NewReader(output))

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var row networkLine
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			continue
		}

		if row.Name == "" || isPseudoNetwork(row.Name) {
			continue
		}

		networks = append(networks, Network{
			ID:     shortNetworkID(row.ID),
			Name:   row.Name,
			Driver: row.Driver,
			Scope:  defaultNetworkScope(),
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	sort.Slice(networks, func(i, j int) bool {
		return networks[i].Name < networks[j].Name
	})

	return networks, nil
}

// firstSubnet returns the first non-empty subnet from inspect IPAM config.
func firstSubnet(row enrichedNetworkInspectRow) string {
	for _, config := range row.IPAM.Config {
		subnet := strings.TrimSpace(config.Subnet)
		if subnet != "" {
			return subnet
		}
	}

	return ""
}

// firstGateway returns the first non-empty gateway from inspect IPAM config.
func firstGateway(row enrichedNetworkInspectRow) string {
	for _, config := range row.IPAM.Config {
		gateway := strings.TrimSpace(config.Gateway)
		if gateway != "" {
			return gateway
		}
	}

	return ""
}

// defaultNetworkScope returns the scope used when inspect output omits one.
func defaultNetworkScope() string {
	return "local"
}

// firstNonEmpty returns the first non-blank string from values.
func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}

	return ""
}

// shortNetworkID truncates a network ID to a 12-character display form.
func shortNetworkID(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}

	if len(value) > 12 {
		return value[:12]
	}

	return value
}

// humanizeNetworkCreated formats a network creation timestamp for display.
func humanizeNetworkCreated(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}

	return humanizeTime(value)
}

// queryNerdctlNetworks lists networks via nerdctl JSON output.
func queryNerdctlNetworks(ctx context.Context, run commandRunner) ([]Network, error) {
	output, err := run(ctx, "nerdctl", "network", "ls", "--format", "{{json .}}")
	if err != nil {
		return nil, err
	}

	return ParseNetworkLines(output)
}

// queryDockerNetworks lists networks via docker CLI JSON output.
func queryDockerNetworks(ctx context.Context, run commandRunner) ([]Network, error) {
	output, err := run(ctx, "docker", "network", "ls", "--format", "{{json .}}")
	if err != nil {
		return nil, err
	}

	return ParseNetworkLines(output)
}

// mergeNetworksByName combines nerdctl and docker network lists, preferring nerdctl entries on name collision.
func mergeNetworksByName(nerdctlNetworks, dockerNetworks []Network) []Network {
	if len(dockerNetworks) == 0 {
		return nerdctlNetworks
	}

	seen := make(map[string]int, len(nerdctlNetworks))
	for i := range nerdctlNetworks {
		seen[nerdctlNetworks[i].Name] = i
	}

	result := make([]Network, len(nerdctlNetworks), len(nerdctlNetworks)+len(dockerNetworks))
	copy(result, nerdctlNetworks)

	for _, dn := range dockerNetworks {
		if _, exists := seen[dn.Name]; exists {
			continue
		}
		seen[dn.Name] = len(result)
		result = append(result, dn)
	}

	return result
}
