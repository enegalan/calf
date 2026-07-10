package runtime

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
)

const NerdctlBin = "/usr/local/bin/nerdctl"

const defaultExecTerm = "xterm-256color"

var logTailLines = strconv.Itoa(constants.LogTailLineCount)

// NerdctlVMArgs prefixes nerdctl arguments with sudo and the VM binary path.
func NerdctlVMArgs(args ...string) []string {
	return append([]string{"sudo", NerdctlBin}, args...)
}

// interactiveExecArgs builds nerdctl exec flags for an interactive shell session.
func interactiveExecArgs(id string) []string {
	return []string{
		"exec",
		"-it",
		"-e", "TERM=" + defaultExecTerm,
		id,
		"/bin/sh",
	}
}

type nerdctlLine struct {
	ID         string            `json:"ID"`
	Names      string            `json:"Names"`
	Name       string            `json:"Name"`
	Driver     string            `json:"Driver"`
	Image      string            `json:"Image"`
	State      string            `json:"State"`
	Status     string            `json:"Status"`
	CreatedAt  string            `json:"CreatedAt"`
	Ports      string            `json:"Ports"`
	Labels     map[string]string `json:"Labels"`
	Repository string            `json:"Repository"`
	Tag        string            `json:"Tag"`
	Size       string            `json:"Size"`
}

type commandRunner func(ctx context.Context, command string, args ...string) ([]byte, error)

type stdinCommandRunner func(ctx context.Context, stdin, command string, args ...string) ([]byte, error)

// listContainers runs nerdctl ps and parses JSON lines into Container values.
func listContainers(ctx context.Context, run commandRunner) ([]Container, error) {
	output, err := run(ctx, "nerdctl", "ps", "-a", "--format", "{{json .}}")
	if err != nil {
		return nil, err
	}

	return ParseContainerLines(output)
}

// listImages runs nerdctl images and parses JSON lines into Image values.
func listImages(ctx context.Context, run commandRunner) ([]Image, error) {
	output, err := run(ctx, "nerdctl", "images", "--format", "{{json .}}")
	if err != nil {
		return nil, err
	}

	return ParseImageLines(output)
}

// listVolumes runs nerdctl volume ls and parses JSON lines into Volume values.
func listVolumes(ctx context.Context, run commandRunner) ([]Volume, error) {
	output, err := run(ctx, "nerdctl", "volume", "ls", "--format", "{{json .}}")
	if err != nil {
		return nil, err
	}

	return ParseVolumeLines(output)
}

// runBuild runs nerdctl build and enriches the parsed output with image metadata.
func runBuild(ctx context.Context, run commandRunner, contextPath, tag, dockerfile, platform string) (BuildResult, error) {
	args := []string{"build", "--progress=plain", "-t", tag}
	if dockerfile != "" {
		args = append(args, "-f", dockerfile)
	}
	if platform != "" {
		args = append(args, "--platform", platform)
	}

	args = append(args, contextPath)
	output, err := run(ctx, "nerdctl", args...)
	result := ParseBuildOutput(string(output))
	if err != nil {
		return result, err
	}

	return enrichBuildResult(ctx, run, contextPath, dockerfile, tag, platform, result), nil
}

// runImage starts a detached container from ref and returns its ID.
func runImage(ctx context.Context, run commandRunner, ref string) (string, error) {
	output, err := run(ctx, "nerdctl", "run", "-d", ref)
	if err != nil {
		return "", err
	}

	return strings.TrimSpace(string(output)), nil
}

// pushImage runs nerdctl push and wraps auth failures with a helpful hint.
func pushImage(ctx context.Context, run commandRunner, ref string) error {
	_, err := run(ctx, "nerdctl", "push", ref)
	if err != nil {
		return wrapPushError(ref, err)
	}

	return nil
}

// ParseContainerLines decodes newline-delimited nerdctl ps JSON into containers.
func ParseContainerLines(output []byte) ([]Container, error) {
	containers := make([]Container, 0)
	seen := make(map[string]struct{})
	scanner := bufio.NewScanner(bytes.NewReader(output))

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var row struct {
			ID        string          `json:"ID"`
			Names     string          `json:"Names"`
			Image     string          `json:"Image"`
			State     string          `json:"State"`
			Status    string          `json:"Status"`
			Ports     string          `json:"Ports"`
			CreatedAt string          `json:"CreatedAt"`
			Labels    json.RawMessage `json:"Labels"`
		}
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			continue
		}

		if row.ID == "" {
			continue
		}
		if _, exists := seen[row.ID]; exists {
			continue
		}
		seen[row.ID] = struct{}{}

		containerName := row.Names
		if containerName == "" {
			containerName = row.ID
		}

		labels := parseLabels(row.Labels)
		project, service := composeFields(containerName, labels)

		containers = append(containers, Container{
			ID:             row.ID,
			Name:           containerName,
			Image:          row.Image,
			State:          containerState(row.Status, row.State),
			Status:         row.Status,
			Ports:          row.Ports,
			Created:        row.CreatedAt,
			ComposeProject: project,
			ComposeService: service,
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	inferComposeProjects(containers)

	return containers, nil
}

// parseLabels decodes nerdctl label output. The comma-separated path is
// intentional: label values that contain commas will be split and fragments
// without '=' are ignored, matching nerdctl's default formatting.
func parseLabels(raw json.RawMessage) map[string]string {
	if len(raw) == 0 {
		return nil
	}

	if raw[0] == '{' {
		var labels map[string]string
		if err := json.Unmarshal(raw, &labels); err == nil {
			return labels
		}
		return nil
	}

	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil
	}
	if s == "" {
		return nil
	}

	labels := make(map[string]string)
	for _, pair := range strings.Split(s, ",") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		parts := strings.SplitN(pair, "=", 2)
		if len(parts) == 2 {
			labels[parts[0]] = parts[1]
		}
	}

	return labels
}

// ParseImageLines decodes newline-delimited nerdctl images JSON into images.
func ParseImageLines(output []byte) ([]Image, error) {
	images := make([]Image, 0)
	scanner := bufio.NewScanner(bytes.NewReader(output))

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var row nerdctlLine
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			continue
		}

		images = append(images, Image{
			ID:         row.ID,
			Repository: row.Repository,
			Tag:        row.Tag,
			Size:       row.Size,
			Created:    row.CreatedAt,
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return images, nil
}

type historyLine struct {
	CreatedSince string `json:"CreatedSince"`
	CreatedBy    string `json:"CreatedBy"`
	Size         string `json:"Size"`
}

// imageHistory runs nerdctl history for ref and returns ordered layers.
func imageHistory(ctx context.Context, run commandRunner, ref string) ([]ImageLayer, error) {
	output, err := run(ctx, "nerdctl", "history", "--no-trunc", "--format", "{{json .}}", ref)
	if err != nil {
		return nil, err
	}

	return ParseImageHistoryLines(output)
}

// ParseImageHistoryLines decodes nerdctl history JSON into base-to-top layers.
func ParseImageHistoryLines(output []byte) ([]ImageLayer, error) {
	entries := make([]historyLine, 0)
	scanner := bufio.NewScanner(bytes.NewReader(output))

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var row historyLine
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			continue
		}

		entries = append(entries, row)
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	for left, right := 0, len(entries)-1; left < right; left, right = left+1, right-1 {
		entries[left], entries[right] = entries[right], entries[left]
	}

	layers := make([]ImageLayer, 0, len(entries))
	for index, entry := range entries {
		layers = append(layers, ImageLayer{
			Index:     index,
			CreatedBy: formatLayerCommand(entry.CreatedBy),
			Size:      entry.Size,
			Created:   entry.CreatedSince,
		})
	}

	return layers, nil
}

// formatLayerCommand normalizes Dockerfile history command text for display.
func formatLayerCommand(createdBy string) string {
	createdBy = strings.TrimSpace(createdBy)
	createdBy = strings.TrimPrefix(createdBy, "/bin/sh -c ")

	if len(createdBy) >= 2 && createdBy[0] == '(' && createdBy[len(createdBy)-1] == ')' {
		createdBy = strings.TrimSpace(createdBy[1 : len(createdBy)-1])
	}

	return strings.ReplaceAll(createdBy, "#(nop)  ", "")
}

type volumeLine struct {
	Name   string `json:"Name"`
	Driver string `json:"Driver"`
	Size   string `json:"Size"`
}

// ParseVolumeLines decodes newline-delimited nerdctl volume ls JSON into volumes.
func ParseVolumeLines(output []byte) ([]Volume, error) {
	volumes := make([]Volume, 0)
	scanner := bufio.NewScanner(bytes.NewReader(output))

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var row volumeLine
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			continue
		}

		volumes = append(volumes, Volume{
			Name:   row.Name,
			Driver: row.Driver,
			Size:   strings.TrimSpace(row.Size),
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return volumes, nil
}

var composeNamePattern = regexp.MustCompile(`^(.+)-([^-]+)-(\d+)$`)

// composeFields extracts compose project and service from labels or container name.
func composeFields(name string, labels map[string]string) (string, string) {
	if labels != nil {
		project := labels["com.docker.compose.project"]
		if project != "" {
			return project, labels["com.docker.compose.service"]
		}
	}

	matches := composeNamePattern.FindStringSubmatch(name)
	if len(matches) == 4 {
		return matches[1], matches[2]
	}

	return "", ""
}

// inferComposeProjects fills missing compose metadata using name and image heuristics.
func inferComposeProjects(containers []Container) {
	names := make(map[string]struct{}, len(containers))
	for _, container := range containers {
		names[container.Name] = struct{}{}
	}

	for index := range containers {
		if containers[index].ComposeProject != "" {
			continue
		}

		name := containers[index].Name
		project := longestComposePrefix(name, names)
		if project != "" {
			containers[index].ComposeProject = project
			containers[index].ComposeService = composeServiceName(name, project)
			continue
		}

		for candidate := range names {
			if candidate != name && strings.HasPrefix(candidate, name+"-") {
				containers[index].ComposeProject = name
				containers[index].ComposeService = composeServiceName(name, name)
				break
			}
		}

		if containers[index].ComposeProject != "" {
			continue
		}

		project = sharedNamePrefix(name, names)
		if project != "" {
			containers[index].ComposeProject = project
			containers[index].ComposeService = composeServiceName(name, project)
			continue
		}
	}

	inferComposeProjectsFromImages(containers)
}

// sharedNamePrefix finds the longest shared dash-separated prefix among container names.
func sharedNamePrefix(name string, names map[string]struct{}) string {
	parts := strings.Split(name, "-")
	if len(parts) < 2 {
		return ""
	}

	var project string
	for i := len(parts) - 1; i >= 1; i-- {
		prefix := strings.Join(parts[:i], "-")
		for candidate := range names {
			if candidate == name {
				continue
			}

			if strings.HasPrefix(candidate, prefix+"-") {
				if len(prefix) > len(project) {
					project = prefix
				}
				break
			}
		}
	}

	return project
}

// inferComposeProjectsFromImages assigns compose groups when multiple containers share an image prefix.
func inferComposeProjectsFromImages(containers []Container) {
	projectCounts := make(map[string]int)
	for _, container := range containers {
		if container.ComposeProject != "" {
			continue
		}

		project, _ := imageComposeFields(container.Image)
		if project != "" {
			projectCounts[project]++
		}
	}

	for index := range containers {
		if containers[index].ComposeProject != "" {
			continue
		}

		project, service := imageComposeFields(containers[index].Image)
		if project == "" || projectCounts[project] < 2 {
			continue
		}

		containers[index].ComposeProject = project
		containers[index].ComposeService = service
	}
}

// imageComposeFields splits an image repository name into project and service parts.
func imageComposeFields(image string) (string, string) {
	repository := imageRepositoryName(image)
	lastDash := strings.LastIndex(repository, "-")
	if lastDash <= 0 {
		return "", ""
	}

	return repository[:lastDash], repository[lastDash+1:]
}

// longestComposePrefix returns the longest name prefix that names another container in the set.
func longestComposePrefix(name string, names map[string]struct{}) string {
	var project string

	for candidate := range names {
		if candidate == name {
			continue
		}

		if strings.HasPrefix(name, candidate+"-") {
			if project == "" || len(candidate) > len(project) {
				project = candidate
			}
		}
	}

	return project
}

// composeServiceName derives the compose service name from a container name and project.
func composeServiceName(name, project string) string {
	service := strings.TrimPrefix(name, project+"-")
	if service == "" {
		return name
	}

	return service
}

// containerState normalizes nerdctl State and Status fields into a single state string.
func containerState(status, state string) string {
	if state != "" {
		return strings.ToLower(state)
	}

	status = strings.TrimSpace(status)
	switch {
	case strings.HasPrefix(status, "Up"):
		return "running"
	case strings.Contains(status, "Exited"):
		return "exited"
	case status == "Created":
		return "created"
	case strings.Contains(status, "Paused"):
		return "paused"
	default:
		return "stopped"
	}
}

// streamCommandLogs runs command and streams stdout lines to output until it exits.
func streamCommandLogs(ctx context.Context, command *exec.Cmd, output func(string)) error {
	stdout, err := command.StdoutPipe()
	if err != nil {
		return err
	}

	stderr, err := command.StderrPipe()
	if err != nil {
		return err
	}

	if err := command.Start(); err != nil {
		return err
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		pipeLines(stdout, output)
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(io.Discard, stderr)
	}()

	waitErr := command.Wait()
	wg.Wait()

	if ctx.Err() != nil {
		return ctx.Err()
	}

	return waitErr
}

// logsFollowSince returns an RFC3339Nano timestamp for nerdctl logs --since.
func logsFollowSince() string {
	return time.Now().UTC().Format(time.RFC3339Nano)
}

// emitLogLines sends buffered log text to output, skipping known noise lines.
func emitLogLines(output func(string), data []byte) {
	if len(data) == 0 {
		return
	}

	text := strings.TrimSuffix(string(data), "\n")
	if text == "" {
		return
	}

	for _, line := range strings.Split(text, "\n") {
		if isNoiseLogLine(line) {
			continue
		}
		output(line)
	}
}

// streamLogs tails and follows container logs via a local nerdctl subprocess.
func streamLogs(ctx context.Context, run commandRunner, id string, output func(string)) error {
	command := exec.CommandContext(ctx, "sh", "-c", fmt.Sprintf("nerdctl logs -f --tail %s %q", logTailLines, id))
	return streamCommandLogs(ctx, command, output)
}

// pipeLines reads reader line by line and forwards non-noise lines to output.
func pipeLines(reader io.Reader, output func(string)) {
	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		line := scanner.Text()
		if isNoiseLogLine(line) {
			continue
		}
		output(line)
	}
}

// isNoiseLogLine reports whether a log line should be filtered from the stream.
func isNoiseLogLine(line string) bool {
	switch {
	case strings.Contains(line, "tail: inotify cannot be used"):
		return true
	case strings.Contains(line, "mux_client_request_session"):
		return true
	case strings.Contains(line, "ControlSocket") && strings.Contains(line, "ssh.sock"):
		return true
	case strings.Contains(line, "disabling multiplexing"):
		return true
	default:
		return false
	}
}
