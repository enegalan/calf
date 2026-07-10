package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"path"
	"strings"
	"unicode"
)

type ContainerMount struct {
	Type        string `json:"type"`
	Name        string `json:"name,omitempty"`
	Source      string `json:"source"`
	Destination string `json:"destination"`
	Mode        string `json:"mode,omitempty"`
	RW          bool   `json:"rw"`
}

type ContainerFileEntry struct {
	Name     string `json:"name"`
	Path     string `json:"path"`
	IsDir    bool   `json:"is_dir"`
	Size     int64  `json:"size"`
	Mode     string `json:"mode"`
	Modified string `json:"modified,omitempty"`
	Note     string `json:"note,omitempty"`
}

type ContainerStats struct {
	CPUPerc  string `json:"cpu_percent"`
	MemUsage string `json:"mem_usage"`
	MemPerc  string `json:"mem_percent"`
	NetIO    string `json:"net_io"`
	BlockIO  string `json:"block_io"`
	PIDs     string `json:"pids"`
}

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
		return nil, err
	}

	var rows []json.RawMessage
	if err := json.Unmarshal(output, &rows); err != nil || len(rows) == 0 {
		return nil, fmt.Errorf("inspect container %s", id)
	}

	return rows[0], nil
}

// parseContainerMounts extracts mounts from inspect JSON, including HostConfig bind mounts.
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
	for _, mount := range payload.Mounts {
		mounts = append(mounts, ContainerMount{
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

		mounts = append(mounts, ContainerMount{
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

// listContainerFiles runs ls -la inside a container at dirPath.
func listContainerFiles(ctx context.Context, run commandRunner, id, dirPath string) ([]ContainerFileEntry, error) {
	if dirPath == "" {
		dirPath = "/"
	}

	script := fmt.Sprintf("ls -la %q", dirPath)
	output, err := run(ctx, "nerdctl", "exec", id, "sh", "-c", script)
	if err != nil {
		return nil, err
	}

	return parseLsOutput(dirPath, output), nil
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

// attachExecInContainer wires an interactive PTY exec to stdin, output, and resize channels.
func attachExecInContainer(ctx context.Context, command *exec.Cmd, stdin io.Reader, onOutput func([]byte), resizeCh <-chan ExecResize) error {
	return attachContainerExec(ctx, command, stdin, onOutput, resizeCh)
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

// prettyInspectJSON reformats raw inspect JSON with indentation.
func prettyInspectJSON(raw json.RawMessage) (string, error) {
	var buffer bytes.Buffer
	if err := json.Indent(&buffer, raw, "", "  "); err != nil {
		return "", err
	}

	return buffer.String(), nil
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
