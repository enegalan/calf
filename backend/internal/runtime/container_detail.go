package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"path"
	"strings"
	"unicode"
)

// ContainerMount represents a mount in a container.
type ContainerMount struct {
	Type        string `json:"type"`
	Name        string `json:"name,omitempty"`
	Source      string `json:"source"`
	Destination string `json:"destination"`
	Mode        string `json:"mode,omitempty"`
	RW          bool   `json:"rw"`
}

// ContainerFileEntry represents a file entry in a container.
type ContainerFileEntry struct {
	Name     string `json:"name"`
	Path     string `json:"path"`
	IsDir    bool   `json:"is_dir"`
	Size     int64  `json:"size"`
	Mode     string `json:"mode"`
	Modified string `json:"modified,omitempty"`
	Note     string `json:"note,omitempty"`
}

// ContainerStats represents the stats of a container.
type ContainerStats struct {
	CPUPerc  string `json:"cpu_percent"`
	MemUsage string `json:"mem_usage"`
	MemPerc  string `json:"mem_percent"`
	NetIO    string `json:"net_io"`
	BlockIO  string `json:"block_io"`
	PIDs     string `json:"pids"`
}

// nerdctlStatsLine represents the stats of a container from nerdctl stats output.
type nerdctlStatsLine struct {
	CPUPerc  string `json:"CPUPerc"`
	MemUsage string `json:"MemUsage"`
	MemPerc  string `json:"MemPerc"`
	NetIO    string `json:"NetIO"`
	BlockIO  string `json:"BlockIO"`
	PIDs     string `json:"PIDs"`
}

// inspectContainer runs nerdctl inspect and returns the first container document.
func inspectContainer(ctx context.Context, run commandRunner, id string) (json.RawMessage, error) {
	output, err := run(ctx, "nerdctl", "inspect", id)
	if err != nil {
		if IsContainerNotFoundError(err) {
			return nil, ErrContainerNotFound
		}
		return nil, err
	}

	var rows []json.RawMessage
	if err := json.Unmarshal(output, &rows); err != nil {
		return nil, fmt.Errorf("inspect container %s: %w", id, err)
	}
	if len(rows) == 0 {
		return nil, ErrContainerNotFound
	}

	return rows[0], nil
}

// parseContainerMounts extracts mounts from inspect JSON, including HostConfig bind mounts.
// Mounts is preferred; HostConfig.Binds fills gaps and is skipped when the destination already exists.
func parseContainerMounts(inspect json.RawMessage) ([]ContainerMount, error) {
	var payload struct {
		Mounts []struct {
			Type        string `json:"Type"`
			Name        string `json:"Name"`
			Source      string `json:"Source"`
			Destination string `json:"Destination"`
			Mode        string `json:"Mode"`
			RW          bool   `json:"RW"`
		} `json:"Mounts"`
		HostConfig struct {
			Binds []string `json:"Binds"`
		} `json:"HostConfig"`
	}

	if err := json.Unmarshal(inspect, &payload); err != nil {
		return nil, err
	}

	mounts := make([]ContainerMount, 0, len(payload.Mounts)+len(payload.HostConfig.Binds))
	seenDestinations := make(map[string]struct{}, len(payload.Mounts)+len(payload.HostConfig.Binds))
	addMount := func(mount ContainerMount) {
		key := mount.Destination
		if key == "" {
			key = mount.Source
		}
		if key == "" {
			return
		}
		if _, exists := seenDestinations[key]; exists {
			return
		}
		seenDestinations[key] = struct{}{}
		mounts = append(mounts, mount)
	}

	for _, mount := range payload.Mounts {
		addMount(ContainerMount{
			Type:        mount.Type,
			Name:        mount.Name,
			Source:      mount.Source,
			Destination: mount.Destination,
			Mode:        mount.Mode,
			RW:          mount.RW,
		})
	}

	for _, bind := range payload.HostConfig.Binds {
		source, destination, mode, ok := parseBindMount(bind)
		if !ok {
			continue
		}

		addMount(ContainerMount{
			Type:        "bind",
			Source:      source,
			Destination: destination,
			Mode:        mode,
			RW:          !strings.Contains(mode, "ro"),
		})
	}

	return mounts, nil
}

// parseBindMount splits a Docker bind string into source, destination, and mode.
func parseBindMount(bind string) (string, string, string, bool) {
	parts := strings.Split(bind, ":")
	if len(parts) < 2 {
		return "", "", "", false
	}

	source := parts[0]
	destination := parts[1]
	mode := ""
	if len(parts) > 2 {
		mode = parts[2]
	}

	return source, destination, mode, true
}

// listContainerFiles lists directory entries inside a container at dirPath.
// Running containers use exec; stopped containers fall back to docker/nerdctl cp + tar.
func listContainerFiles(ctx context.Context, run commandRunner, id, dirPath string) ([]ContainerFileEntry, error) {
	if dirPath == "" {
		dirPath = "/"
	}

	script := fmt.Sprintf("ls -la '%s'", shellQuote(dirPath))
	output, err := run(ctx, "nerdctl", "exec", id, "sh", "-c", script)
	if err == nil {
		return parseLsOutput(dirPath, output), nil
	}

	if IsContainerNotFoundError(err) {
		return nil, ErrContainerNotFound
	}

	if !IsContainerNotRunningError(err) {
		return nil, err
	}

	entries, archiveErr := listContainerFilesFromArchive(ctx, run, id, dirPath)
	if archiveErr == nil {
		return entries, nil
	}

	if IsContainerNotFoundError(archiveErr) {
		return nil, ErrContainerNotFound
	}

	return nil, fmt.Errorf("%w: %v", ErrContainerNotRunning, archiveErr)
}

// listContainerFilesFromArchive lists one directory level via `docker/nerdctl cp | tar -tv`.
// Works for stopped containers where exec is unavailable.
func listContainerFilesFromArchive(ctx context.Context, run commandRunner, id, dirPath string) ([]ContainerFileEntry, error) {
	copyPath := dirPath
	if copyPath == "" {
		copyPath = "/"
	}

	ref := id + ":" + copyPath
	script := fmt.Sprintf(
		`(command -v docker >/dev/null 2>&1 && docker cp '%s' - || nerdctl cp '%s' -) | tar -tv`,
		shellQuote(ref),
		shellQuote(ref),
	)
	output, err := run(ctx, "sh", "-c", script)
	if err != nil {
		if IsContainerNotFoundError(err) {
			return nil, ErrContainerNotFound
		}
		return nil, err
	}

	return parseTarTvOutput(dirPath, output), nil
}

// parseLsOutput converts ls -la output into entries for the given directory path.
func parseLsOutput(dirPath string, output []byte) []ContainerFileEntry {
	lines := strings.Split(string(output), "\n")
	entries := make([]ContainerFileEntry, 0, len(lines))

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "total ") {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) < 8 {
			continue
		}

		mode := fields[0]
		name := strings.Join(fields[8:], " ")
		if name == "." || name == ".." {
			continue
		}

		if strings.HasPrefix(name, "'") && strings.HasSuffix(name, "'") {
			name = strings.Trim(name, "'")
		}

		isDir := strings.HasPrefix(mode, "d")
		isLink := strings.HasPrefix(mode, "l")
		entryPath := path.Join(dirPath, name)
		if dirPath == "/" {
			entryPath = "/" + name
		}

		var size int64
		fmt.Sscanf(fields[4], "%d", &size)

		note := ""
		if isLink {
			if arrow := strings.Index(name, " -> "); arrow >= 0 {
				note = strings.TrimSpace(name[arrow+4:])
				name = strings.TrimSpace(name[:arrow])
				entryPath = path.Join(dirPath, name)
				if dirPath == "/" {
					entryPath = "/" + name
				}
			}
		}

		modified := strings.Join(fields[5:8], " ")
		entries = append(entries, ContainerFileEntry{
			Name:     name,
			Path:     entryPath,
			IsDir:    isDir,
			Size:     size,
			Mode:     mode,
			Modified: modified,
			Note:     note,
		})
	}

	return entries
}

// ParseTarTvOutput converts `tar -tv` output into immediate children of dirPath.
func ParseTarTvOutput(dirPath string, output []byte) []ContainerFileEntry {
	return parseTarTvOutput(dirPath, output)
}

// parseTarTvOutput converts `tar -tv` output into immediate children of dirPath.
func parseTarTvOutput(dirPath string, output []byte) []ContainerFileEntry {
	lines := strings.Split(string(output), "\n")
	entries := make([]ContainerFileEntry, 0)
	seen := make(map[string]struct{})

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}

		mode := fields[0]
		name := fields[len(fields)-1]
		note := ""
		metaFields := fields
		if arrow := strings.Index(line, " -> "); arrow >= 0 {
			note = strings.TrimSpace(line[arrow+4:])
			before := strings.TrimSpace(line[:arrow])
			beforeFields := strings.Fields(before)
			if len(beforeFields) > 0 {
				name = beforeFields[len(beforeFields)-1]
				metaFields = beforeFields
			}
		}

		childName, ok := tarImmediateChildName(dirPath, name)
		if !ok {
			continue
		}

		if _, exists := seen[childName]; exists {
			continue
		}
		seen[childName] = struct{}{}

		isDir := strings.HasPrefix(mode, "d") || strings.HasSuffix(name, "/")
		isLink := strings.HasPrefix(mode, "l")
		entryPath := path.Join(dirPath, childName)
		if dirPath == "/" {
			entryPath = "/" + childName
		}

		size, modified := tarTvSizeAndModified(metaFields, isDir)

		if isLink && note == "" {
			note = "symlink"
		}

		entries = append(entries, ContainerFileEntry{
			Name:     childName,
			Path:     entryPath,
			IsDir:    isDir,
			Size:     size,
			Mode:     mode,
			Modified: modified,
			Note:     note,
		})
	}

	return entries
}

// tarTvSizeAndModified extracts size and mtime from BusyBox, GNU, or BSD `tar -tv` columns.
// metaFields is mode plus owner/size/date columns and the member name (last field).
func tarTvSizeAndModified(metaFields []string, isDir bool) (int64, string) {
	if len(metaFields) < 3 {
		return 0, ""
	}

	body := metaFields[1 : len(metaFields)-1]
	dateStart := -1
	for index, field := range body {
		if tarTvIsMonth(field) || tarTvIsISODate(field) {
			dateStart = index
			break
		}
	}

	if dateStart < 0 {
		sizeIndex := -1
		for index := len(body) - 1; index >= 0; index-- {
			if tarTvAllDigits(body[index]) {
				sizeIndex = index
				break
			}
		}
		if sizeIndex < 0 {
			return 0, strings.Join(body, " ")
		}
		var size int64
		if !isDir {
			fmt.Sscanf(body[sizeIndex], "%d", &size)
		}
		return size, strings.Join(body[sizeIndex+1:], " ")
	}

	modified := strings.Join(body[dateStart:], " ")
	var size int64
	if !isDir {
		for index := dateStart - 1; index >= 0; index-- {
			if !tarTvAllDigits(body[index]) {
				continue
			}
			fmt.Sscanf(body[index], "%d", &size)
			break
		}
	}
	return size, modified
}

// tarTvIsMonth reports whether field is an English month abbreviation used by tar.
func tarTvIsMonth(field string) bool {
	switch field {
	case "Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec":
		return true
	default:
		return false
	}
}

// tarTvIsISODate reports whether field looks like YYYY-MM-DD.
func tarTvIsISODate(field string) bool {
	if len(field) != 10 || field[4] != '-' || field[7] != '-' {
		return false
	}
	return tarTvAllDigits(field[0:4]) && tarTvAllDigits(field[5:7]) && tarTvAllDigits(field[8:10])
}

// tarTvAllDigits reports whether value is a non-empty decimal integer field.
func tarTvAllDigits(value string) bool {
	if value == "" {
		return false
	}
	for _, runeValue := range value {
		if runeValue < '0' || runeValue > '9' {
			return false
		}
	}
	return true
}

// tarImmediateChildName returns the immediate child basename under dirPath from a tar member path.
func tarImmediateChildName(dirPath, entryName string) (string, bool) {
	entryName = strings.TrimPrefix(entryName, "./")
	entryName = strings.TrimPrefix(entryName, "/")
	entryName = strings.TrimSuffix(entryName, "/")
	if entryName == "" || entryName == "." {
		return "", false
	}

	base := strings.Trim(dirPath, "/")
	if base == "" {
		if strings.Contains(entryName, "/") {
			return "", false
		}
		return entryName, true
	}

	prefix := base + "/"
	if !strings.HasPrefix(entryName, prefix) {
		return "", false
	}

	rest := strings.TrimPrefix(entryName, prefix)
	if rest == "" || strings.Contains(rest, "/") {
		return "", false
	}

	return rest, true
}

// execInContainer runs a shell command in a container and returns trimmed stdout.
func execInContainer(ctx context.Context, run commandRunner, id string, command string) (string, error) {
	command = strings.TrimSpace(command)
	if command == "" {
		return "", fmt.Errorf("command is required")
	}

	output, err := run(ctx, "nerdctl", "exec", id, "sh", "-c", command)
	if err != nil {
		if len(output) > 0 {
			return strings.TrimSpace(string(output)), err
		}
		return "", err
	}

	return strings.TrimSpace(string(output)), nil
}

// containerStats fetches a single nerdctl stats snapshot for a container.
func containerStats(ctx context.Context, run commandRunner, id string) (ContainerStats, error) {
	output, err := run(ctx, "nerdctl", "stats", "--no-stream", "--format", "{{json .}}", id)
	if err != nil {
		return ContainerStats{}, err
	}

	line := strings.TrimSpace(string(bytes.TrimSpace(output)))
	if line == "" {
		return ContainerStats{}, fmt.Errorf("stats unavailable for container %s", id)
	}

	var row nerdctlStatsLine
	if err := json.Unmarshal([]byte(line), &row); err != nil {
		return ContainerStats{}, err
	}

	return ContainerStats{
		CPUPerc:  strings.TrimSpace(row.CPUPerc),
		MemUsage: strings.TrimSpace(row.MemUsage),
		MemPerc:  strings.TrimSpace(row.MemPerc),
		NetIO:    strings.TrimSpace(row.NetIO),
		BlockIO:  strings.TrimSpace(row.BlockIO),
		PIDs:     strings.TrimSpace(row.PIDs),
	}, nil
}

// restartContainer restarts a container via nerdctl.
func restartContainer(ctx context.Context, run commandRunner, id string) error {
	_, err := run(ctx, "nerdctl", "restart", id)
	return err
}

// InspectSection returns one top-level inspect key, matching case-insensitively when needed.
func InspectSection(raw json.RawMessage, section string) (json.RawMessage, error) {
	section = strings.TrimSpace(section)
	if section == "" {
		return raw, nil
	}

	var payload map[string]json.RawMessage
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, err
	}

	value, ok := payload[section]
	if !ok {
		for key, candidate := range payload {
			if strings.EqualFold(key, section) {
				value = candidate
				ok = true
				break
			}
		}
	}

	if !ok {
		return nil, fmt.Errorf("section %q not found", section)
	}

	return value, nil
}

// isValidContainerPath reports whether a container filesystem path is safe to use.
func isValidContainerPath(value string) bool {
	if value == "" {
		return true
	}

	if !strings.HasPrefix(value, "/") {
		return false
	}

	for _, r := range value {
		if unicode.IsControl(r) {
			return false
		}
	}

	return true
}
