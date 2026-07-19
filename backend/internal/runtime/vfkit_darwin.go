//go:build darwin

package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
)

// Vfkit runs a Linux guest via vfkit and exposes Docker over virtio-vsock.
type Vfkit struct {
	mu           sync.Mutex
	vmName       string
	dockerSocket string
	cpus         int
	memoryGB     int
	vmKeepAlive  bool
	proxy        ProxyConfig
	dataDir      string
	started      atomic.Bool
	cmd          *exec.Cmd
}

// NewVfkit constructs a vfkit-backed Runtime for macOS.
func NewVfkit(vmName, dockerSocket string, cpus, memoryGB, _, _ int, vmKeepAlive bool, proxy ProxyConfig) *Vfkit {
	if vmName == "" {
		vmName = constants.DefaultVMName
	}
	if dockerSocket == "" {
		dockerSocket = config.DefaultDockerSocketPath()
	}
	home, err := os.UserHomeDir()
	if err != nil {
		home = os.TempDir()
	}
	if cpus < 1 {
		cpus = 4
	}
	if memoryGB < 1 {
		memoryGB = 4
	}
	if override := os.Getenv("CALF_VFKIT_MEMORY_GB"); override != "" {
		if n, err := strconv.Atoi(override); err == nil && n > 0 {
			memoryGB = n
		}
	}
	return &Vfkit{
		vmName:       vmName,
		dockerSocket: dockerSocket,
		cpus:         cpus,
		memoryGB:     memoryGB,
		vmKeepAlive:  vmKeepAlive,
		proxy:        proxy,
		dataDir:      filepath.Join(home, ".config", "calf", "vfkit", vmName),
	}
}

// DockerSocket returns the host unix socket bridged to guest Docker via vsock.
func (v *Vfkit) DockerSocket() string { return v.dockerSocket }

func (v *Vfkit) diskPath() string { return filepath.Join(v.dataDir, "disk.raw") }
func (v *Vfkit) efiPath() string  { return filepath.Join(v.dataDir, "efi-store") }
func (v *Vfkit) pidPath() string  { return filepath.Join(v.dataDir, "vfkit.pid") }

// resolveVfkitBinary returns the vfkit executable: CALF_VFKIT_BIN, next to this process, or PATH.
func resolveVfkitBinary() string {
	if override := strings.TrimSpace(os.Getenv("CALF_VFKIT_BIN")); override != "" {
		if _, err := os.Stat(override); err == nil {
			return override
		}
	}
	if exe, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(exe), "vfkit")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	if path, err := exec.LookPath("vfkit"); err == nil {
		return path
	}
	return ""
}

// resolveSeedArchive returns a compressed guest disk path used for first-run extract.
func resolveSeedArchive(dataDir string) string {
	if override := strings.TrimSpace(os.Getenv("CALF_VFKIT_DISK_ZST")); override != "" {
		if _, err := os.Stat(override); err == nil {
			return override
		}
	}
	candidates := []string{
		filepath.Join(dataDir, "disk.raw.zst"),
		filepath.Join(dataDir, guestDiskAssetName()),
	}
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(dir, "disk.raw.zst"),
			filepath.Join(dir, "..", "Resources", "disk.raw.zst"),
			filepath.Join(dir, "..", "Resources", "vfkit-disk.raw.zst"),
		)
	}
	for _, path := range candidates {
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	return ""
}

// ensureGuestDisk ensures disk.raw exists: local file, local .zst seed, or GitHub download.
func (v *Vfkit) ensureGuestDisk(ctx context.Context) error {
	if _, err := os.Stat(v.diskPath()); err == nil {
		return nil
	}
	if err := os.MkdirAll(v.dataDir, 0o755); err != nil {
		return err
	}
	seed := resolveSeedArchive(v.dataDir)
	if seed == "" {
		dlCtx, cancel := context.WithTimeout(ctx, 45*time.Minute)
		defer cancel()
		downloaded, err := v.downloadGuestDisk(dlCtx)
		if err != nil {
			return fmt.Errorf("vfkit disk missing at %s (%w); run make guest-vfkit or set CALF_VFKIT_DISK_URL", v.diskPath(), err)
		}
		seed = downloaded
	}
	return v.extractGuestSeed(seed)
}

// ensureHostMountSymlink makes host ~/.config/calf/mounts resolve inside the guest via /mnt/calf.
func (v *Vfkit) ensureHostMountSymlink(ctx context.Context) {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return
	}
	hostMounts := filepath.Join(home, ".config", "calf", "mounts")
	script := "mkdir -p /mnt/calf && mkdir -p \"/host" + filepath.Dir(hostMounts) + "\" && ln -sfn /mnt/calf \"/host" + hostMounts + "\""
	_, _ = v.runLocal(ctx, "docker", "run", "--rm", "--privileged", "-v", "/:/host", "alpine:3.20", "sh", "-c", script)
}

// Start launches vfkit and waits for Docker /_ping on the vsock-bridged socket.
func (v *Vfkit) Start(ctx context.Context) error {
	vfkitBin := resolveVfkitBinary()
	if vfkitBin == "" {
		return fmt.Errorf("vfkit not found: install with brew install vfkit, or place vfkit next to calf-daemon")
	}
	if _, err := exec.LookPath("docker"); err != nil {
		return fmt.Errorf("docker CLI not found: required for the vfkit runtime (install the Docker CLI and ensure it is on PATH)")
	}
	if err := v.ensureGuestDisk(ctx); err != nil {
		return err
	}
	if err := os.MkdirAll(v.dataDir, 0o755); err != nil {
		return err
	}
	if v.dockerAPIReady(ctx) && v.processAlive() {
		v.started.Store(true)
		return nil
	}
	_ = v.stopProcess()
	// Wait for the previous guest to release the disk before relaunching.
	deadline := time.Now().Add(15 * time.Second)
	for v.processAlive() && time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	_ = os.Remove(v.dockerSocket)
	if err := os.MkdirAll(filepath.Dir(v.dockerSocket), 0o755); err != nil {
		return err
	}

	bootloader := "efi,variable-store=" + v.efiPath() + ",create"
	if _, err := os.Stat(v.efiPath()); err == nil {
		bootloader = "efi,variable-store=" + v.efiPath()
	}
	home, err := os.UserHomeDir()
	if err != nil {
		home = os.TempDir()
	}
	mounts := filepath.Join(home, ".config", "calf", "mounts")
	_ = os.MkdirAll(mounts, 0o755)
	args := []string{
		"--cpus", strconv.Itoa(v.cpus),
		"--memory", strconv.Itoa(v.memoryGB * 1024),
		"--bootloader", bootloader,
		"--device", "virtio-blk,path=" + v.diskPath(),
		"--device", "virtio-net,nat",
		"--device", "virtio-fs,sharedDir=" + mounts + ",mountTag=calf-mounts",
		"--device", "virtio-vsock,port=2375,socketURL=" + v.dockerSocket + ",connect",
	}
	if os.Getenv("CALF_VFKIT_ROSETTA") == "1" {
		args = append(args, "--device", "rosetta,mountTag=calf-rosetta,install")
	}
	args = append(args,
		"--pidfile", v.pidPath(),
		"--log-level", "info",
	)
	cmd := exec.Command(vfkitBin, args...)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start vfkit: %w", err)
	}
	v.mu.Lock()
	v.cmd = cmd
	v.mu.Unlock()
	go func() { _ = cmd.Wait(); v.started.Store(false) }()

	if err := v.waitForDockerAPI(ctx); err != nil {
		_ = v.stopProcess()
		return err
	}
	v.ensureHostMountSymlink(ctx)
	v.started.Store(true)
	return nil
}

// Stop kills vfkit unless vm_keep_alive is enabled (benchmarks force a full stop).
func (v *Vfkit) Stop(ctx context.Context) error {
	_ = ctx
	v.started.Store(false)
	if v.vmKeepAlive && os.Getenv("CALF_BENCHMARK") != "1" {
		return nil
	}
	_ = v.stopProcess()
	_ = os.Remove(v.dockerSocket)
	return nil
}

func (v *Vfkit) stopProcess() error {
	v.mu.Lock()
	cmd := v.cmd
	v.cmd = nil
	v.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Signal(syscall.SIGTERM)
		time.Sleep(200 * time.Millisecond)
		_ = cmd.Process.Kill()
	}
	if data, err := os.ReadFile(v.pidPath()); err == nil {
		if pid, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil && pid > 1 {
			_ = syscall.Kill(pid, syscall.SIGTERM)
			time.Sleep(150 * time.Millisecond)
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	}
	_ = os.Remove(v.pidPath())
	return nil
}

func (v *Vfkit) processAlive() bool {
	data, err := os.ReadFile(v.pidPath())
	if err != nil {
		return false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid < 1 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}

// Status reports whether the vfkit Docker API is reachable.
func (v *Vfkit) Status(ctx context.Context) (Status, error) {
	st := Status{Mode: Mode(constants.RuntimeModeVM), State: State(constants.RuntimeStateStopped), DockerSocket: v.dockerSocket, VMName: v.vmName}
	if v.dockerAPIReady(ctx) {
		st.State = State(constants.RuntimeStateRunning)
	}
	return st, nil
}

func (v *Vfkit) waitForDockerAPI(ctx context.Context) error {
	deadline := time.Now().Add(10 * time.Minute)
	delay := 50 * time.Millisecond
	for time.Now().Before(deadline) {
		if v.dockerAPIReady(ctx) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
		if delay < constants.DockerAPIReadyPollMax {
			delay *= 2
			if delay > constants.DockerAPIReadyPollMax {
				delay = constants.DockerAPIReadyPollMax
			}
		}
	}
	return fmt.Errorf("docker API not ready for vfkit VM %q", v.vmName)
}

func (v *Vfkit) dockerAPIReady(ctx context.Context) bool {
	client := &http.Client{Timeout: 400 * time.Millisecond, Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", v.dockerSocket)
		},
		DisableKeepAlives: true,
	}}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://localhost/_ping", nil)
	if err != nil {
		return false
	}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func (v *Vfkit) runLocal(ctx context.Context, command string, args ...string) ([]byte, error) {
	if command == "nerdctl" {
		command = "docker"
	}
	env := os.Environ()
	env = dockerHostEnvFrom(env, v.dockerSocket)
	if v.proxy != (ProxyConfig{}) {
		env = proxyEnvFrom(env, v.proxy)
	}
	return runCommandWithRetryEnv(ctx, constants.DefaultCommandRetries, constants.DefaultCommandRetryDelay, env, "", command, args...)
}

func (v *Vfkit) runLocalWithStdin(ctx context.Context, stdin, command string, args ...string) ([]byte, error) {
	if command == "nerdctl" {
		command = "docker"
	}
	env := dockerHostEnvFrom(os.Environ(), v.dockerSocket)
	return runCommandWithRetryEnv(ctx, constants.DefaultCommandRetries, constants.DefaultCommandRetryDelay, env, stdin, command, args...)
}

func (v *Vfkit) ListContainers(ctx context.Context) ([]Container, error) {
	return emptyIfStopped(ctx, v.Status, func(ctx context.Context) ([]Container, error) { return listContainers(ctx, v.runLocal) })
}
func (v *Vfkit) ListImages(ctx context.Context) ([]Image, error) {
	return emptyIfStopped(ctx, v.Status, func(ctx context.Context) ([]Image, error) { return listImages(ctx, v.runLocal) })
}
func (v *Vfkit) ImageHistory(ctx context.Context, ref string) ([]ImageLayer, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return nil, err
	}
	return imageHistory(ctx, v.runLocal, ref)
}
func (v *Vfkit) ListVolumes(ctx context.Context) ([]Volume, error) {
	return emptyIfStopped(ctx, v.Status, func(ctx context.Context) ([]Volume, error) {
		vols, err := listVolumes(ctx, v.runLocal)
		if err != nil {
			return nil, err
		}
		return enrichVolumesInUse(ctx, v.runLocal, vols)
	})
}
func (v *Vfkit) ListNetworks(ctx context.Context) ([]Network, error) {
	return emptyIfStopped(ctx, v.Status, func(ctx context.Context) ([]Network, error) { return listNetworks(ctx, v.runLocal) })
}
func (v *Vfkit) InspectNetwork(ctx context.Context, name string) (NetworkDetail, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return NetworkDetail{}, err
	}
	return inspectNetwork(ctx, v.runLocal, name)
}
func (v *Vfkit) RemoveNetwork(ctx context.Context, name string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	return removeNetwork(ctx, v.runLocal, name)
}
func (v *Vfkit) ApplyProxy(ctx context.Context, proxy ProxyConfig) error { v.proxy = proxy; return nil }
func (v *Vfkit) CreateVolume(ctx context.Context, name string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	args := []string{"volume", "create"}
	if name != "" {
		args = append(args, name)
	}
	_, err := v.runLocal(ctx, "nerdctl", args...)
	return err
}
func (v *Vfkit) CloneVolume(ctx context.Context, source, dest string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	return cloneVolume(ctx, v.runLocal, source, dest)
}
func (v *Vfkit) ExportVolume(ctx context.Context, opts VolumeExportOptions) (string, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return "", err
	}
	return RunVolumeExport(ctx, v.runLocal, opts)
}
func (v *Vfkit) RemoveVolume(ctx context.Context, name string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	_, err := v.runLocal(ctx, "nerdctl", "volume", "rm", name)
	return err
}
func (v *Vfkit) InspectVolume(ctx context.Context, name string) (VolumeDetail, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return VolumeDetail{}, err
	}
	return inspectVolume(ctx, v.runLocal, name)
}
func (v *Vfkit) ListVolumeFiles(ctx context.Context, name, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return nil, err
	}
	if !isValidContainerPath(path) {
		return nil, fmt.Errorf("invalid path")
	}
	return listVolumeFiles(ctx, v.runLocal, name, path)
}
func (v *Vfkit) VolumeContainers(ctx context.Context, name string) ([]VolumeContainerUsage, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return nil, err
	}
	return volumeContainerUsages(ctx, v.runLocal, name)
}
func (v *Vfkit) RunBuild(ctx context.Context, contextPath, tag, dockerfile, platform string) (BuildResult, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return BuildResult{}, err
	}
	return runBuild(ctx, v.runLocal, contextPath, tag, dockerfile, platform)
}
func (v *Vfkit) StartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	_, err := v.runLocal(ctx, "nerdctl", "start", id)
	return err
}
func (v *Vfkit) StopContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	_, err := v.runLocal(ctx, "nerdctl", "stop", id)
	return err
}
func (v *Vfkit) RemoveContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	_, err := v.runLocal(ctx, "nerdctl", "rm", "-f", id)
	return err
}
func (v *Vfkit) RemoveImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	_, err := v.runLocal(ctx, "nerdctl", "rmi", ref)
	return err
}
func (v *Vfkit) PullImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	_, err := v.runLocal(ctx, "nerdctl", "pull", ref)
	return err
}
func (v *Vfkit) PushImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	return pushImage(ctx, v.runLocal, ref)
}
func (v *Vfkit) RunImage(ctx context.Context, ref string) (string, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return "", err
	}
	return runImage(ctx, v.runLocal, ref)
}
func (v *Vfkit) StreamLogs(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	history, err := v.runLocal(ctx, "nerdctl", "logs", "--tail", logTailLines, id)
	if err == nil {
		emitLogLines(output, history)
	}
	return v.streamLogsFollow(ctx, id, logsFollowSince(), output)
}
func (v *Vfkit) StreamLogsFollow(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	return v.streamLogsFollow(ctx, id, logsFollowSince(), output)
}
func (v *Vfkit) streamLogsFollow(ctx context.Context, id, since string, output func(string)) error {
	command := exec.CommandContext(ctx, "docker", "logs", "-f", "--since", since, id)
	command.Env = dockerHostEnvFrom(os.Environ(), v.dockerSocket)
	return streamCommandLogs(ctx, command, output)
}
func (v *Vfkit) InspectContainer(ctx context.Context, id string) (json.RawMessage, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return nil, err
	}
	return inspectContainer(ctx, v.runLocal, id)
}
func (v *Vfkit) ContainerMounts(ctx context.Context, id string) ([]ContainerMount, error) {
	inspect, err := v.InspectContainer(ctx, id)
	if err != nil {
		return nil, err
	}
	return parseContainerMounts(inspect)
}
func (v *Vfkit) ListContainerFiles(ctx context.Context, id, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return nil, err
	}
	if !isValidContainerPath(path) {
		return nil, fmt.Errorf("invalid path")
	}
	return listContainerFiles(ctx, v.runLocal, id, path)
}
func (v *Vfkit) ExecContainer(ctx context.Context, id, command string) (string, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return "", err
	}
	return execInContainer(ctx, v.runLocal, id, command)
}
func (v *Vfkit) AttachExec(ctx context.Context, id string, stdin io.Reader, onOutput func([]byte), resizeCh <-chan ExecResize) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	command := exec.CommandContext(ctx, "docker", interactiveExecArgs(id)...)
	command.Env = dockerHostEnvFrom(os.Environ(), v.dockerSocket)
	return attachContainerExec(ctx, command, stdin, onOutput, resizeCh)
}
func (v *Vfkit) ContainerStats(ctx context.Context, id string) (ContainerStats, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return ContainerStats{}, err
	}
	return containerStats(ctx, v.runLocal, id)
}
func (v *Vfkit) RestartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	return restartContainer(ctx, v.runLocal, id)
}
func (v *Vfkit) RegistryStatus(ctx context.Context) (RegistryStatus, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return RegistryStatus{Server: constants.DefaultRegistryServer}, nil
	}
	home, _ := os.UserHomeDir()
	return registryStatus(ctx, v.runLocal, filepath.Join(home, ".docker", "config.json"))
}
func (v *Vfkit) RegistryLogin(ctx context.Context, server, username, password string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	return registryLogin(ctx, v.runLocal, v.runLocalWithStdin, server, username, password)
}
func (v *Vfkit) RegistryLogout(ctx context.Context, server string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	return registryLogout(ctx, v.runLocal, server)
}
