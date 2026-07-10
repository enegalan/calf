package migration

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/internal/utils"
)

type Options struct {
	CalfSocket string
	VMName     string
	RunNerdctl func(ctx context.Context, args ...string) error
	OnStatus   func(Status)
	SaveConfig func(config.Config) error
	AddBuild   func(runtime.Build)
	Logger     *slog.Logger
}

type dockerSettings struct {
	CPUs      int `json:"Cpus"`
	MemoryMiB int `json:"MemoryMiB"`
	SwapMiB   int `json:"SwapMiB"`
}

type parsedSettings struct {
	CPUs     int
	MemoryGB int
	SwapGB   int
}

type containerInspect struct {
	Name   string `json:"Name"`
	Config struct {
		Image      string            `json:"Image"`
		Env        []string          `json:"Env"`
		Cmd        []string          `json:"Cmd"`
		Entrypoint []string          `json:"Entrypoint"`
		WorkingDir string            `json:"WorkingDir"`
		Hostname   string            `json:"Hostname"`
		User       string            `json:"User"`
		Labels     map[string]string `json:"Labels"`
	} `json:"Config"`
	HostConfig struct {
		NetworkMode  string   `json:"NetworkMode"`
		Binds        []string `json:"Binds"`
		ExtraHosts   []string `json:"ExtraHosts"`
		PortBindings map[string][]struct {
			HostIP   string `json:"HostIp"`
			HostPort string `json:"HostPort"`
		} `json:"PortBindings"`
		RestartPolicy struct {
			Name string `json:"Name"`
		} `json:"RestartPolicy"`
	} `json:"HostConfig"`
	Mounts []struct {
		Type        string `json:"Type"`
		Name        string `json:"Name"`
		Source      string `json:"Source"`
		Destination string `json:"Destination"`
		Mode        string `json:"Mode"`
		RW          bool   `json:"RW"`
	} `json:"Mounts"`
	State struct {
		Status string `json:"Status"`
	} `json:"State"`
}

type buildHistoryRow struct {
	Name      string `json:"Name"`
	Status    string `json:"Status"`
	CreatedAt string `json:"CreatedAt"`
}

// DockerDesktopSocket returns the first existing Docker Desktop unix socket path on the host.
func DockerDesktopSocket() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}

	candidates := []string{
		filepath.Join(home, ".docker", "run", "docker.sock"),
		filepath.Join(home, "Library", "Containers", "com.docker.docker", "Data", "docker-cli.sock"),
	}

	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}

	return ""
}

// StagingDir returns the host directory used for temporary migration tar exports.
func StagingDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	dir := filepath.Join(home, ".config", "calf", "mounts", "migrate")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}

	return dir, nil
}

// VMPath maps a host path under ~/.config/calf/mounts to its Lima VM mount equivalent.
func VMPath(hostPath string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return hostPath
	}

	mountsRoot := filepath.Join(home, ".config", "calf", "mounts")
	rel, err := filepath.Rel(mountsRoot, hostPath)
	if err != nil {
		return hostPath
	}

	return "/mnt/calf/" + filepath.ToSlash(rel)
}

// RunFromDockerDesktop migrates images, volumes, containers, config, and build history from Docker Desktop to Calf.
func RunFromDockerDesktop(ctx context.Context, opts Options) Status {
	if opts.Logger != nil {
		opts.Logger.Info("starting docker desktop migration")
	}

	status := Status{Phase: PhaseRunning, Step: "preflight", Progress: 0, Message: "Checking Docker Desktop"}
	emit := func(update Status) {
		status = update
		if opts.OnStatus != nil {
			opts.OnStatus(status)
		}
	}
	emit(status)

	ddSocket := DockerDesktopSocket()
	if ddSocket == "" {
		status.Phase = PhaseFailed
		status.Error = "Docker Desktop socket not found"
		emit(status)
		return status
	}

	if _, err := exec.LookPath("docker"); err != nil {
		status.Phase = PhaseFailed
		status.Error = "docker CLI not found in PATH"
		emit(status)
		return status
	}

	if _, err := runDocker(ctx, ddSocket, "info"); err != nil {
		status.Phase = PhaseFailed
		status.Error = "Docker Desktop is not running"
		emit(status)
		return status
	}

	if opts.CalfSocket == "" {
		status.Phase = PhaseFailed
		status.Error = "Calf docker socket is not configured"
		emit(status)
		return status
	}

	if _, err := os.Stat(opts.CalfSocket); err != nil {
		status.Phase = PhaseFailed
		status.Error = "Calf runtime is not running"
		emit(status)
		return status
	}

	staging, err := StagingDir()
	if err != nil {
		status.Phase = PhaseFailed
		status.Error = err.Error()
		emit(status)
		return status
	}

	vmName := opts.VMName
	if vmName == "" {
		vmName = "calf"
	}

	status.Step = "preflight"
	status.Progress = 2
	status.Message = "Checking disk space"
	emit(status)

	if err := checkMigrationDiskSpace(ctx, vmName, ddSocket); err != nil {
		status.Phase = PhaseFailed
		status.Error = err.Error()
		emit(status)
		return status
	}

	if err := migrateConfig(ctx, ddSocket, opts, &status, emit); err != nil {
		status.Phase = PhaseFailed
		status.Error = err.Error()
		emit(status)
		return status
	}

	if err := migrateImages(ctx, ddSocket, opts, staging, &status, emit); err != nil {
		status.Phase = PhaseFailed
		status.Error = err.Error()
		emit(status)
		return status
	}

	if err := migrateVolumes(ctx, ddSocket, opts, staging, &status, emit); err != nil {
		status.Phase = PhaseFailed
		status.Error = err.Error()
		emit(status)
		return status
	}

	if err := migrateContainers(ctx, ddSocket, opts, &status, emit); err != nil {
		status.Phase = PhaseFailed
		status.Error = err.Error()
		emit(status)
		return status
	}

	migrateBuilds(ctx, ddSocket, opts, &status, emit)

	status.Phase = PhaseCompleted
	status.Step = "done"
	status.Progress = 100
	status.Message = formatCompletionMessage(status.Summary)
	emit(status)
	return status
}

// formatCompletionMessage summarizes migration results, noting partial failures when counts differ.
func formatCompletionMessage(summary Summary) string {
	if summary.ImagesOK < summary.ImagesTotal ||
		summary.VolumesOK < summary.VolumesTotal ||
		summary.ContainersOK < summary.ContainersTotal {
		return fmt.Sprintf(
			"Migration completed with warnings (images %d/%d, volumes %d/%d, containers %d/%d, builds %d/%d)",
			summary.ImagesOK, summary.ImagesTotal,
			summary.VolumesOK, summary.VolumesTotal,
			summary.ContainersOK, summary.ContainersTotal,
			summary.BuildsOK, summary.BuildsTotal,
		)
	}

	return "Migration completed"
}

// migrateConfig copies Docker Desktop CPU and memory settings into the Calf config when available.
func migrateConfig(ctx context.Context, _ string, opts Options, status *Status, emit func(Status)) error {
	status.Step = "config"
	status.Progress = 5
	status.Message = "Migrating Docker Desktop settings"
	emit(*status)

	settings, ok := readDockerDesktopSettings()
	if !ok || opts.SaveConfig == nil {
		return nil
	}

	cfg := config.Default()
	cfg.CPUs = settings.CPUs
	cfg.MemoryGB = settings.MemoryGB
	cfg.MemorySwapGB = settings.SwapGB

	if err := opts.SaveConfig(cfg); err != nil {
		return fmt.Errorf("save config: %w", err)
	}

	status.Summary.ConfigApplied = true
	emit(*status)
	return nil
}

// migrateImages exports each Docker Desktop image to a tar and loads it into Calf.
func migrateImages(ctx context.Context, ddSocket string, opts Options, staging string, status *Status, emit func(Status)) error {
	status.Step = "images"
	status.Message = "Migrating images"
	emit(*status)

	refs, err := listImageRefs(ctx, ddSocket)
	if err != nil {
		return err
	}

	status.Summary.ImagesTotal = len(refs)
	emit(*status)

	for index, ref := range refs {
		status.Progress = 10 + (index*35)/max(len(refs), 1)
		status.Message = fmt.Sprintf("Migrating image %s", ref)
		emit(*status)

		tarPath := filepath.Join(staging, fmt.Sprintf("image-%d.tar", index))
		if _, err := runDocker(ctx, ddSocket, "save", "-o", tarPath, ref); err != nil {
			if opts.Logger != nil {
				opts.Logger.Warn("image export failed", "ref", ref, "error", err)
			}
			continue
		}

		if err := loadImageOnCalf(ctx, opts, tarPath); err == nil {
			status.Summary.ImagesOK++
		} else if opts.Logger != nil {
			opts.Logger.Warn("image import failed", "ref", ref, "error", err)
		}

		_ = os.Remove(tarPath)
		emit(*status)
	}

	return nil
}

// loadImageOnCalf imports a saved image tar into the Calf runtime via nerdctl or docker.
func loadImageOnCalf(ctx context.Context, opts Options, tarPath string) error {
	if opts.RunNerdctl != nil {
		return opts.RunNerdctl(ctx, "load", "-i", VMPath(tarPath))
	}

	return runDockerError(ctx, opts.CalfSocket, "load", "-i", tarPath)
}

// migrateVolumes exports each Docker Desktop volume and recreates it on Calf.
func migrateVolumes(ctx context.Context, ddSocket string, opts Options, staging string, status *Status, emit func(Status)) error {
	status.Step = "volumes"
	status.Progress = 50
	status.Message = "Migrating volumes"
	emit(*status)

	_, _ = runDocker(ctx, ddSocket, "pull", constants.AlpineSmokeImage)
	if opts.RunNerdctl != nil {
		_ = opts.RunNerdctl(ctx, "pull", constants.AlpineSmokeImage)
	}

	names, err := listVolumeNames(ctx, ddSocket)
	if err != nil {
		return err
	}

	status.Summary.VolumesTotal = len(names)
	emit(*status)

	for index, name := range names {
		status.Progress = 50 + (index*20)/max(len(names), 1)
		status.Message = fmt.Sprintf("Migrating volume %s", name)
		emit(*status)

		tarName := sanitizeFileName(name) + ".tar.gz"
		tarPath := filepath.Join(staging, tarName)
		vmTarPath := VMPath(tarPath)

		exportArgs := []string{
			"run", "--rm",
			"-v", name + ":/from:ro",
			"-v", staging + ":/to",
			constants.AlpineSmokeImage,
			"tar", "czf", "/to/" + tarName, "-C", "/from", ".",
		}
		if _, err := runDocker(ctx, ddSocket, exportArgs...); err != nil {
			if opts.Logger != nil {
				opts.Logger.Warn("volume export failed", "volume", name, "error", err)
			}
			continue
		}

		if err := createVolumeOnCalf(ctx, opts, name); err != nil {
			_ = os.Remove(tarPath)
			if opts.Logger != nil {
				opts.Logger.Warn("volume create failed", "volume", name, "error", err)
			}
			continue
		}

		if err := importVolumeOnCalf(ctx, opts, name, vmTarPath, tarName); err == nil {
			status.Summary.VolumesOK++
		} else if opts.Logger != nil {
			opts.Logger.Warn("volume import failed", "volume", name, "error", err)
		}

		_ = os.Remove(tarPath)
		emit(*status)
	}

	return nil
}

// createVolumeOnCalf creates a named volume in the Calf runtime.
func createVolumeOnCalf(ctx context.Context, opts Options, name string) error {
	if opts.RunNerdctl != nil {
		return opts.RunNerdctl(ctx, "volume", "create", name)
	}

	return runDockerError(ctx, opts.CalfSocket, "volume", "create", name)
}

// importVolumeOnCalf restores a staged volume tar archive into a Calf volume.
func importVolumeOnCalf(ctx context.Context, opts Options, name, vmTarPath, tarName string) error {
	importArgs := []string{
		"run", "--rm",
		"-v", name + ":/to",
		"-v", "/mnt/calf/migrate:/from:ro",
		constants.AlpineSmokeImage,
		"sh", "-c", "cd /to && tar xzf /from/" + tarName,
	}

	if opts.RunNerdctl != nil {
		return opts.RunNerdctl(ctx, importArgs...)
	}

	return runDockerError(ctx, opts.CalfSocket, importArgs...)
}

// migrateContainers recreates standalone and compose-group containers on Calf, preserving run state.
func migrateContainers(ctx context.Context, ddSocket string, opts Options, status *Status, emit func(Status)) error {
	status.Step = "containers"
	status.Progress = 75
	status.Message = "Migrating containers"
	emit(*status)

	ids, err := listContainerIDs(ctx, ddSocket)
	if err != nil {
		return err
	}

	status.Summary.ContainersTotal = len(ids)
	emit(*status)

	inspects := make([]containerInspect, 0, len(ids))
	running := make(map[string]bool, len(ids))

	for _, id := range ids {
		inspect, wasRunning, err := inspectContainer(ctx, ddSocket, id)
		if err != nil {
			continue
		}

		name := strings.TrimPrefix(inspect.Name, "/")
		running[name] = wasRunning
		inspects = append(inspects, inspect)
	}

	stoppedOnSource := make([]string, 0, len(inspects))

	for _, inspect := range inspects {
		name := strings.TrimPrefix(inspect.Name, "/")
		if !running[name] {
			continue
		}

		if _, err := runDocker(ctx, ddSocket, "stop", name); err == nil {
			stoppedOnSource = append(stoppedOnSource, name)
		}
	}

	migrated := make(map[string]struct{}, len(inspects))

	defer func() {
		for _, name := range stoppedOnSource {
			if _, ok := migrated[name]; ok {
				continue
			}

			_, _ = runDocker(ctx, ddSocket, "start", name)
		}
	}()

	composeGroups, standalone := groupContainersByComposeProject(inspects, running)
	mountsRoot, err := composeMountsRoot()
	if err != nil {
		return err
	}

	for _, group := range composeGroups {
		status.Message = fmt.Sprintf("Migrating compose project %s", group.Name)
		emit(*status)

		if err := migrateComposeProject(ctx, opts, group, mountsRoot); err != nil {
			if opts.Logger != nil {
				opts.Logger.Warn("compose project import failed", "project", group.Name, "error", err)
			}
			continue
		}

		for _, inspect := range group.Containers {
			migrated[strings.TrimPrefix(inspect.Name, "/")] = struct{}{}
			status.Summary.ContainersOK++
		}
		emit(*status)
	}

	remaining := append([]containerInspect{}, standalone...)
	for _, group := range composeGroups {
		for _, inspect := range group.Containers {
			name := strings.TrimPrefix(inspect.Name, "/")
			if _, ok := migrated[name]; ok {
				continue
			}
			remaining = append(remaining, inspect)
		}
	}

	for index, inspect := range remaining {
		name := strings.TrimPrefix(inspect.Name, "/")
		status.Progress = 75 + (index*20)/max(len(remaining), 1)
		status.Message = fmt.Sprintf("Migrating container %s", name)
		emit(*status)

		if err := createContainerOnCalf(ctx, opts, inspect); err != nil {
			if opts.Logger != nil {
				opts.Logger.Warn("container import failed", "container", inspect.Name, "error", err)
			}
			continue
		}

		if running[name] {
			var startErr error
			if opts.RunNerdctl != nil {
				startErr = opts.RunNerdctl(ctx, "start", name)
			} else {
				_, startErr = runDocker(ctx, opts.CalfSocket, "start", name)
			}
			if startErr != nil {
				if opts.Logger != nil {
					opts.Logger.Warn("container start failed", "container", name, "error", startErr)
				}
				continue
			}
		}

		status.Summary.ContainersOK++
		emit(*status)
	}

	return nil
}

// composeMountsRoot returns the host mounts root directory, creating it when missing.
func composeMountsRoot() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	root := filepath.Join(home, ".config", "calf", "mounts")
	if err := os.MkdirAll(root, 0o755); err != nil {
		return "", err
	}

	return root, nil
}

// migrateComposeProject stages a compose project and runs compose up on Calf.
func migrateComposeProject(ctx context.Context, opts Options, group composeProjectGroup, mountsRoot string) error {
	vmDir, vmComposePath, err := stageComposeProject(group, mountsRoot)
	if err != nil {
		return err
	}

	args := []string{
		"compose",
		"-p", group.Name,
		"-f", vmComposePath,
		"--project-directory", vmDir,
		"up", "-d",
	}

	if opts.RunNerdctl != nil {
		if err := opts.RunNerdctl(ctx, args...); err != nil {
			return err
		}
	} else {
		if err := runDockerError(ctx, opts.CalfSocket, args...); err != nil {
			return err
		}
	}

	for name, shouldStart := range group.WasRunning {
		if !shouldStart {
			if opts.RunNerdctl != nil {
				_ = opts.RunNerdctl(ctx, "stop", name)
			} else {
				_, _ = runDocker(ctx, opts.CalfSocket, "stop", name)
			}
		}
	}

	return nil
}

// migrateBuilds imports Docker Desktop buildx history entries into the in-memory build store.
func migrateBuilds(ctx context.Context, ddSocket string, opts Options, status *Status, emit func(Status)) {
	status.Step = "builds"
	status.Progress = 95
	status.Message = "Migrating build history"
	emit(*status)

	if opts.AddBuild == nil {
		return
	}

	output, err := runDocker(ctx, ddSocket, "buildx", "history", "ls", "--format", "{{json .}}")
	if err != nil {
		output, err = runDocker(ctx, ddSocket, "buildx", "ls", "--format", "{{json .}}")
		if err != nil {
			return
		}
	}

	rows := parseBuildHistory(output)
	status.Summary.BuildsTotal = len(rows)
	emit(*status)

	for _, row := range rows {
		tag := row.Name
		if tag == "" {
			tag = "migrated-build"
		}

		createdAt := row.CreatedAt
		if createdAt == "" {
			createdAt = time.Now().UTC().Format(time.RFC3339)
		}

		buildStatus := row.Status
		if buildStatus == "" {
			buildStatus = "migrated"
		}

		opts.AddBuild(runtime.Build{
			Tag:       tag,
			Context:   "docker-desktop",
			Status:    buildStatus,
			CreatedAt: createdAt,
		})
		status.Summary.BuildsOK++
	}

	emit(*status)
}

// readDockerDesktopSettings loads CPU and memory limits from Docker Desktop settings files on macOS.
func readDockerDesktopSettings() (parsedSettings, bool) {
	home, err := os.UserHomeDir()
	if err != nil {
		return parsedSettings{}, false
	}

	paths := []string{
		filepath.Join(home, "Library", "Group Containers", "group.com.docker", "settings-store.json"),
		filepath.Join(home, "Library", "Group Containers", "group.com.docker", "settings.json"),
	}

	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}

		var raw dockerSettings
		if err := json.Unmarshal(data, &raw); err != nil {
			continue
		}

		settings := parsedSettings{
			CPUs: raw.CPUs,
		}

		defaults := config.Default()
		if settings.CPUs <= 0 {
			settings.CPUs = defaults.CPUs
		}
		if raw.MemoryMiB <= 0 {
			settings.MemoryGB = defaults.MemoryGB
		} else {
			settings.MemoryGB = max(raw.MemoryMiB/1024, 1)
		}
		if raw.SwapMiB <= 0 {
			settings.SwapGB = defaults.MemorySwapGB
		} else {
			settings.SwapGB = raw.SwapMiB / 1024
		}

		return settings, true
	}

	return parsedSettings{}, false
}

// listImageRefs returns repository:tag refs from Docker Desktop, excluding dangling entries.
func listImageRefs(ctx context.Context, socket string) ([]string, error) {
	output, err := runDocker(ctx, socket, "images", "--format", "{{.Repository}}:{{.Tag}}")
	if err != nil {
		return nil, err
	}

	return utils.ParseLines(output, func(ref string) bool {
		return !strings.HasPrefix(ref, "<none>")
	}), nil
}

// listVolumeNames returns volume names from the given docker socket.
func listVolumeNames(ctx context.Context, socket string) ([]string, error) {
	output, err := runDocker(ctx, socket, "volume", "ls", "--format", "{{.Name}}")
	if err != nil {
		return nil, err
	}

	return utils.ParseLines(output, nil), nil
}

// listContainerIDs returns all container IDs from the given docker socket.
func listContainerIDs(ctx context.Context, socket string) ([]string, error) {
	output, err := runDocker(ctx, socket, "ps", "-a", "--format", "{{.ID}}")
	if err != nil {
		return nil, err
	}

	return utils.ParseLines(output, nil), nil
}

// inspectContainer fetches inspect JSON for one container and whether it was running.
func inspectContainer(ctx context.Context, socket, id string) (containerInspect, bool, error) {
	output, err := runDocker(ctx, socket, "inspect", id)
	if err != nil {
		return containerInspect{}, false, err
	}

	var rows []containerInspect
	if err := json.Unmarshal(output, &rows); err != nil || len(rows) == 0 {
		return containerInspect{}, false, fmt.Errorf("inspect container %s", id)
	}

	wasRunning := strings.EqualFold(rows[0].State.Status, "running")
	return rows[0], wasRunning, nil
}

// createContainerOnCalf recreates a single container on Calf from a Docker inspect payload.
func createContainerOnCalf(ctx context.Context, opts Options, inspect containerInspect) error {
	name := strings.TrimPrefix(inspect.Name, "/")
	args := []string{"create"}

	if name != "" {
		args = append(args, "--name", name)
	}

	for _, label := range migrationLabels(inspect) {
		args = append(args, "--label", label[0]+"="+label[1])
	}

	for _, env := range inspect.Config.Env {
		args = append(args, "-e", env)
	}

	for _, bind := range containerBindMounts(inspect) {
		args = append(args, "-v", bind)
	}

	if inspect.Config.WorkingDir != "" {
		args = append(args, "-w", inspect.Config.WorkingDir)
	}

	if inspect.Config.Hostname != "" {
		args = append(args, "--hostname", inspect.Config.Hostname)
	}

	if inspect.Config.User != "" {
		args = append(args, "--user", inspect.Config.User)
	}

	for _, host := range inspect.HostConfig.ExtraHosts {
		args = append(args, "--add-host", host)
	}

	if policy := inspect.HostConfig.RestartPolicy.Name; policy != "" && policy != "no" {
		args = append(args, "--restart", policy)
	}

	switch inspect.HostConfig.NetworkMode {
	case "host":
		args = append(args, "--network", "host")
	case "", "default", "bridge":
		// default bridge network
	default:
		if !strings.HasPrefix(inspect.HostConfig.NetworkMode, "container:") {
			args = append(args, "--network", inspect.HostConfig.NetworkMode)
		}
	}

	for port, bindings := range inspect.HostConfig.PortBindings {
		for _, binding := range bindings {
			mapping := binding.HostPort + ":" + strings.Split(port, "/")[0]
			if binding.HostIP != "" && binding.HostIP != "0.0.0.0" {
				mapping = binding.HostIP + ":" + mapping
			}
			args = append(args, "-p", mapping)
		}
	}

	if len(inspect.Config.Entrypoint) > 0 {
		args = append(args, "--entrypoint", inspect.Config.Entrypoint[0])
	}

	args = append(args, inspect.Config.Image)
	args = append(args, inspect.Config.Cmd...)

	if opts.RunNerdctl != nil {
		return opts.RunNerdctl(ctx, args...)
	}

	return runDockerError(ctx, opts.CalfSocket, args...)
}

// containerBindMounts returns -v mount specs from HostConfig.Binds or Mounts when binds are absent.
func containerBindMounts(inspect containerInspect) []string {
	if len(inspect.HostConfig.Binds) > 0 {
		return inspect.HostConfig.Binds
	}

	binds := make([]string, 0, len(inspect.Mounts))
	for _, mount := range inspect.Mounts {
		switch mount.Type {
		case "bind":
			if mount.Source == "" || mount.Destination == "" {
				continue
			}

			spec := mount.Source + ":" + mount.Destination
			if mount.Mode != "" {
				spec += ":" + mount.Mode
			} else if !mount.RW {
				spec += ":ro"
			}

			binds = append(binds, spec)
		case "volume":
			if mount.Destination == "" {
				continue
			}

			volumeName := mount.Name
			if volumeName == "" {
				continue
			}

			spec := volumeName + ":" + mount.Destination
			if mount.Mode != "" {
				spec += ":" + mount.Mode
			} else if !mount.RW {
				spec += ":ro"
			}

			binds = append(binds, spec)
		}
	}

	return binds
}

// parseBuildHistory decodes newline-delimited or plain-text buildx history list output.
func parseBuildHistory(output []byte) []buildHistoryRow {
	rows := make([]buildHistoryRow, 0)
	scanner := bufio.NewScanner(bytes.NewReader(output))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var row buildHistoryRow
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			name := line
			if name != "" {
				rows = append(rows, buildHistoryRow{Name: name, Status: "migrated"})
			}
			continue
		}

		if row.Name == "" {
			continue
		}

		rows = append(rows, row)
	}

	return rows
}

// runDocker executes docker against the given unix socket and returns combined output.
func runDocker(ctx context.Context, socket string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, "docker", args...)
	command.Env = append(os.Environ(), "DOCKER_HOST=unix://"+socket)
	output, err := command.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("docker %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}

	return output, nil
}

// runDockerError runs docker and discards output, returning only the error.
func runDockerError(ctx context.Context, socket string, args ...string) error {
	_, err := runDocker(ctx, socket, args...)
	return err
}

// sanitizeFileName replaces path separators in a name so it is safe for staging file paths.
func sanitizeFileName(name string) string {
	replacer := strings.NewReplacer("/", "_", ":", "_", "\\", "_")
	return replacer.Replace(name)
}

// max returns the larger of two integers.
func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
