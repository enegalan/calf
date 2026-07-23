package runtime

import (
	"context"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// volumeInspectRow represents a row in the nerdctl volume inspect output.
type volumeInspectRow struct {
	CreatedAt  string `json:"CreatedAt"`
	Driver     string `json:"Driver"`
	Mountpoint string `json:"Mountpoint"`
	Name       string `json:"Name"`
}

// volumeInspectMetadata returns inspect metadata for a single volume.
func volumeInspectMetadata(ctx context.Context, run commandRunner, name string) (volumeInspectRow, error) {
	rows, err := volumeInspectMetadataBatch(ctx, run, []string{name})
	if err != nil {
		return volumeInspectRow{}, err
	}

	row, ok := rows[name]
	if !ok {
		return volumeInspectRow{}, fmt.Errorf("inspect volume %s", name)
	}

	return row, nil
}

// volumeInspectMetadataBatch returns inspect metadata for multiple volumes in one nerdctl call.
func volumeInspectMetadataBatch(ctx context.Context, run commandRunner, names []string) (map[string]volumeInspectRow, error) {
	rows := make(map[string]volumeInspectRow, len(names))
	if len(names) == 0 {
		return rows, nil
	}

	args := append([]string{"volume", "inspect"}, names...)
	output, err := run(ctx, "nerdctl", args...)
	if err != nil {
		return nil, err
	}

	var parsed []volumeInspectRow
	parsed, err = decodeInspectDocuments[volumeInspectRow](output)
	if err != nil {
		return nil, err
	}

	for _, row := range parsed {
		if row.Name == "" {
			continue
		}
		rows[row.Name] = row
	}

	return rows, nil
}

// volumeSizesAtPaths runs du -sh on paths and maps each path to a human-readable size.
func volumeSizesAtPaths(ctx context.Context, run commandRunner, paths []string) map[string]string {
	sizes := make(map[string]string, len(paths))
	if len(paths) == 0 {
		return sizes
	}

	args := append([]string{"-sh"}, paths...)
	output, err := run(ctx, "du", args...)
	if err != nil {
		sudoArgs := append([]string{"-n", "du", "-sh"}, paths...)
		output, err = run(ctx, "sudo", sudoArgs...)
		if err != nil {
			return sizes
		}
	}

	for _, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		tab := strings.IndexByte(line, '\t')
		if tab < 0 {
			continue
		}

		size := strings.TrimSpace(line[:tab])
		path := strings.TrimSpace(line[tab+1:])
		if path == "" || size == "" {
			continue
		}

		sizes[path] = size
	}

	return sizes
}

// inspectVolume builds a VolumeDetail from inspect metadata and container usages.
func inspectVolume(ctx context.Context, run commandRunner, name string) (VolumeDetail, error) {
	row, err := volumeInspectMetadata(ctx, run, name)
	if err != nil {
		return VolumeDetail{}, err
	}

	usages, err := volumeContainerUsages(ctx, run, name)
	if err != nil {
		return VolumeDetail{}, err
	}

	return VolumeDetail{
		Name:       row.Name,
		Driver:     row.Driver,
		Created:    humanizeTime(row.CreatedAt),
		InUse:      len(usages) > 0,
		Mountpoint: row.Mountpoint,
	}, nil
}

// listVolumeFiles lists files inside a volume at the given logical path.
func listVolumeFiles(ctx context.Context, run commandRunner, name, path string) ([]ContainerFileEntry, error) {
	if !isValidContainerPath(path) {
		return nil, fmt.Errorf("invalid path")
	}

	row, err := volumeInspectMetadata(ctx, run, name)
	if err != nil {
		return nil, err
	}

	if row.Mountpoint == "" {
		return []ContainerFileEntry{}, nil
	}

	logicalPath := path
	if logicalPath == "" {
		logicalPath = "/"
	}

	hostPath := volumeHostPath(row.Mountpoint, logicalPath)
	return ListFilesAtPath(ctx, run, hostPath, logicalPath)
}

// volumeHostPath maps a volume mountpoint plus logical path to a host filesystem path.
func volumeHostPath(mountpoint, logicalPath string) string {
	if logicalPath == "" || logicalPath == "/" {
		return mountpoint
	}

	return filepath.Join(mountpoint, strings.TrimPrefix(logicalPath, "/"))
}

// ListFilesAtPath lists directory entries at hostPath, presenting paths relative to logicalPath.
func ListFilesAtPath(ctx context.Context, run commandRunner, hostPath, logicalPath string) ([]ContainerFileEntry, error) {
	if logicalPath == "" {
		logicalPath = "/"
	}

	output, err := run(ctx, "ls", "-la", hostPath)
	if err != nil {
		output, err = run(ctx, "sudo", "-n", "ls", "-la", hostPath)
		if err != nil {
			return nil, fmt.Errorf("list files at %s: %w", hostPath, err)
		}
	}

	return parseLsOutput(logicalPath, output), nil
}

// cloneVolume copies all data from source into a newly created dest volume.
func cloneVolume(ctx context.Context, run commandRunner, source, dest string) error {
	source = strings.TrimSpace(source)
	dest = strings.TrimSpace(dest)
	if source == "" || dest == "" {
		return fmt.Errorf("volume name is required")
	}
	if source == dest {
		return fmt.Errorf("source and destination must differ")
	}

	sourceRow, err := volumeInspectMetadata(ctx, run, source)
	if err != nil {
		return err
	}

	if _, err := run(ctx, "nerdctl", "volume", "create", dest); err != nil {
		return err
	}

	destRow, err := volumeInspectMetadata(ctx, run, dest)
	if err != nil {
		_, _ = run(ctx, "nerdctl", "volume", "rm", dest)
		return err
	}

	if sourceRow.Mountpoint == "" || destRow.Mountpoint == "" {
		_, _ = run(ctx, "nerdctl", "volume", "rm", dest)
		return fmt.Errorf("clone volume %s", source)
	}

	if _, err := run(ctx, "cp", "-a", sourceRow.Mountpoint+"/.", destRow.Mountpoint+"/"); err != nil {
		if _, err := run(ctx, "sudo", "-n", "cp", "-a", sourceRow.Mountpoint+"/.", destRow.Mountpoint+"/"); err != nil {
			_, _ = run(ctx, "nerdctl", "volume", "rm", dest)
			return fmt.Errorf("clone volume %s: %w", source, err)
		}
	}

	return nil
}

// volumeContainerUsages returns containers that mount the named volume.
func volumeContainerUsages(ctx context.Context, run commandRunner, volumeName string) ([]VolumeContainerUsage, error) {
	containers, err := listContainers(ctx, run)
	if err != nil {
		return nil, err
	}

	usages := make([]VolumeContainerUsage, 0)
	for _, container := range containers {
		inspect, err := inspectContainer(ctx, run, container.ID)
		if err != nil {
			continue
		}

		mounts, err := parseContainerMounts(inspect)
		if err != nil {
			continue
		}

		for _, mount := range mounts {
			if mount.Type != "volume" || volumeMountName(mount) != volumeName {
				continue
			}

			usages = append(usages, VolumeContainerUsage{
				ID:     container.ID,
				Name:   container.Name,
				Image:  container.Image,
				Port:   ExtractHostTCPPort(container.Ports),
				Target: mount.Destination,
			})
		}
	}

	return usages, nil
}

// volumeNamesInUse collects volume names referenced by any container.
// Inspects containers one-by-one so a single uninspectable or vanished ID
// (docker ps can list entries that docker inspect rejects) does not fail the list.
func volumeNamesInUse(ctx context.Context, run commandRunner) (map[string]struct{}, error) {
	containers, err := listContainers(ctx, run)
	if err != nil {
		return nil, err
	}

	inUse := make(map[string]struct{})
	for _, container := range containers {
		inspect, err := inspectContainer(ctx, run, container.ID)
		if err != nil {
			continue
		}

		mounts, err := parseContainerMounts(inspect)
		if err != nil {
			continue
		}

		for _, mount := range mounts {
			if mount.Type != "volume" {
				continue
			}

			name := volumeMountName(mount)
			if name == "" {
				continue
			}

			inUse[name] = struct{}{}
		}
	}

	return inUse, nil
}

// volumeMountName returns the volume name from a mount, falling back to Source.
func volumeMountName(mount ContainerMount) string {
	if mount.Name != "" {
		return mount.Name
	}

	return mount.Source
}

// enrichVolumesInUse fills InUse, Created, and Size on volume entries and sorts by name.
func enrichVolumesInUse(ctx context.Context, run commandRunner, volumes []Volume) ([]Volume, error) {
	inUse, err := volumeNamesInUse(ctx, run)
	if err != nil {
		inUse = map[string]struct{}{}
	}

	names := make([]string, len(volumes))
	for index := range volumes {
		names[index] = volumes[index].Name
	}

	inspectRows, err := volumeInspectMetadataBatch(ctx, run, names)
	if err != nil {
		inspectRows = map[string]volumeInspectRow{}
	}

	mountpoints := make([]string, 0, len(volumes))
	for index := range volumes {
		if volumes[index].Size != "" {
			continue
		}

		row, ok := inspectRows[volumes[index].Name]
		if !ok || row.Mountpoint == "" {
			continue
		}

		mountpoints = append(mountpoints, row.Mountpoint)
	}

	sizes := volumeSizesAtPaths(ctx, run, mountpoints)

	for index := range volumes {
		_, ok := inUse[volumes[index].Name]
		volumes[index].InUse = ok

		row, ok := inspectRows[volumes[index].Name]
		if !ok {
			continue
		}

		if volumes[index].Created == "" {
			volumes[index].Created = humanizeTime(row.CreatedAt)
		}

		if volumes[index].Size == "" && row.Mountpoint != "" {
			volumes[index].Size = sizes[row.Mountpoint]
		}
	}

	sort.Slice(volumes, func(i, j int) bool {
		return volumes[i].Name < volumes[j].Name
	})

	return volumes, nil
}

// humanizeTime parses an RFC3339 timestamp and returns a relative phrase.
func humanizeTime(value string) string {
	if value == "" {
		return ""
	}

	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		parsed, err = time.Parse(time.RFC3339, value)
		if err != nil {
			return value
		}
	}

	return humanizeDuration(time.Since(parsed))
}

// humanizeDuration formats a duration as a relative past-time phrase.
func humanizeDuration(duration time.Duration) string {
	if duration < time.Minute {
		return "just now"
	}

	if duration < time.Hour {
		minutes := int(duration.Minutes())
		if minutes == 1 {
			return "1 minute ago"
		}

		return fmt.Sprintf("%d minutes ago", minutes)
	}

	if duration < 24*time.Hour {
		hours := int(duration.Hours())
		if hours == 1 {
			return "1 hour ago"
		}

		return fmt.Sprintf("%d hours ago", hours)
	}

	days := int(duration.Hours() / 24)
	if days < 30 {
		if days == 1 {
			return "1 day ago"
		}

		return fmt.Sprintf("%d days ago", days)
	}

	months := days / 30
	if months < 12 {
		if months == 1 {
			return "1 month ago"
		}

		return fmt.Sprintf("%d months ago", months)
	}

	years := months / 12
	if years == 1 {
		return "1 year ago"
	}

	return fmt.Sprintf("%d years ago", years)
}
