package runtime

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

var limaLogger = slog.Default()

//go:embed lima.yaml
var limaTemplate string

type Lima struct {
	mu sync.Mutex

	vmName         string
	dockerSocket   string
	templatePath   string
	cpus           int
	memoryGB       int
	memorySwapGB   int
	diskGB         int
	proxy          ProxyConfig
	started        atomic.Bool
	proxyResync    atomic.Bool
	lastState      State
	localhostProxy *localhostProxies
	watcherCancel  context.CancelFunc
	proxyListener  net.Listener
	dockerProxy    *http.Server
}

// NewLima constructs a Lima VM runtime with resource limits and proxy settings.
func NewLima(vmName string, dockerSocket string, cpus int, memoryGB int, memorySwapGB int, diskGB int, apiListenPort int, proxy ProxyConfig) *Lima {
	if vmName == "" {
		vmName = "calf"
	}

	if dockerSocket == "" {
		dockerSocket = defaultDockerSocket()
	}

	lima := &Lima{
		vmName:         vmName,
		dockerSocket:   dockerSocket,
		cpus:           cpus,
		memoryGB:       memoryGB,
		memorySwapGB:   memorySwapGB,
		diskGB:         diskGB,
		proxy:          proxy,
		localhostProxy: newLocalhostProxies(),
	}
	lima.localhostProxy.setReservedPorts(apiListenPort)

	return lima
}

// DockerSocket returns the path to the Docker-compatible socket on the host.
func (l *Lima) DockerSocket() string {
	return l.dockerSocket
}

// Start creates or boots the Lima VM, waits for nerdctl, and starts port proxies.
func (l *Lima) Start(ctx context.Context) error {
	if _, err := exec.LookPath("limactl"); err != nil {
		return fmt.Errorf("limactl not found: install Lima first")
	}

	if err := l.ensureTemplate(); err != nil {
		return err
	}

	exists, err := l.instanceExists(ctx)
	if err != nil {
		return err
	}

	if !exists {
		if _, err := runCommand(ctx, "limactl", "create", "--name", l.vmName, l.templatePath); err != nil {
			return err
		}
	}

	if _, err := runCommandWithRetry(ctx, defaultCommandRetries, defaultCommandRetryDelay, "", "limactl", "start", l.vmName); err != nil {
		return err
	}

	if err := l.waitForNerdctl(ctx); err != nil {
		return err
	}

	if l.proxy != (ProxyConfig{}) {
		if err := l.ApplyProxy(ctx, l.proxy); err != nil {
			limaLogger.Warn("proxy application during start failed (non-fatal)", "error", err)
		}
	}

	if err := l.ensureDockerCLISocket(); err != nil {
		limaLogger.Warn("failed to set up Docker CLI socket symlink (non-fatal)", "error", err)
	}

	l.started.Store(true)
	wCtx, wCancel := context.WithCancel(context.Background())
	l.watcherCancel = wCancel
	go l.watchPortProxies(wCtx)
	return nil
}

// Stop tears down proxies and stops the Lima VM instance.
func (l *Lima) Stop(ctx context.Context) error {
	if _, err := exec.LookPath("limactl"); err != nil {
		return fmt.Errorf("limactl not found: install Lima first")
	}

	exists, err := l.instanceExists(ctx)
	if err != nil {
		return err
	}

	if !exists {
		return nil
	}

	if l.watcherCancel != nil {
		l.watcherCancel()
		l.watcherCancel = nil
	}

	l.localhostProxy.stopAll()
	l.removeDockerCLISocket()
	l.started.Store(false)

	_, err = runCommand(ctx, "limactl", "stop", l.vmName)
	return err
}

// Status reports VM mode, running state, socket health, and port conflicts.
func (l *Lima) Status(ctx context.Context) (Status, error) {
	status := Status{
		Mode:         ModeVM,
		State:        StateStopped,
		DockerSocket: l.dockerSocket,
		VMName:       l.vmName,
	}

	if _, err := exec.LookPath("limactl"); err != nil {
		limaLogger.Warn("limactl not found", "error", err, "PATH", os.Getenv("PATH"))
		status.Log = "limactl not found: install Lima first"
		return status, nil
	}

	output, err := runCommand(ctx, "limactl", "list", "--format", "{{.Name}}\t{{.Status}}")
	if err != nil {
		limaLogger.Warn("limactl list failed", "error", err)
		status.Log = fmt.Sprintf("limactl list failed: %v", err)
		return status, nil
	}
	limaLogger.Debug("limactl list output", "output", string(output))

	found := false
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) != 2 || fields[0] != l.vmName {
			continue
		}
		found = true

		if strings.Contains(strings.ToLower(fields[1]), "running") {
			status.State = StateRunning
		} else {
			limaLogger.Warn("vm not running", "vm", l.vmName, "status", fields[1])
		}
	}

	if !found {
		status.Log = "VM not found in limactl list"
	}

	if status.State == StateRunning && l.dockerSocket != "" {
		conn, err := net.DialTimeout("unix", l.dockerSocket, 100*time.Millisecond)
		if err != nil {
			if errors.Is(err, syscall.ENOENT) {
				limaLogger.Debug("socket not ready yet (expected during startup)", "socket", l.dockerSocket)
			} else {
				limaLogger.Warn("socket dial failed", "socket", l.dockerSocket, "error", err)
			}
			// Fall back to TCP on port 2375 (via Lima port forward + socat inside VM)
			tcpConn, tcpErr := net.DialTimeout("tcp", "127.0.0.1:2375", 100*time.Millisecond)
			if tcpErr != nil {
				limaLogger.Warn("tcp fallback also failed", "error", tcpErr)
				status.State = StateStopped
				status.Log = fmt.Sprintf("socket dial failed: %v", err)
			} else {
				tcpConn.Close()
			}
		} else {
			conn.Close()
		}
	}

	l.mu.Lock()
	if status.State == StateRunning && l.lastState != StateRunning {
		l.started.Store(true)
		l.proxyResync.Store(true)
	}

	l.lastState = status.State
	l.mu.Unlock()
	status.PortConflicts = l.localhostProxy.conflictsSnapshot()

	return status, nil
}

// ListContainers returns all containers and syncs localhost port proxies.
func (l *Lima) ListContainers(ctx context.Context) ([]Container, error) {
	return emptyIfStopped(ctx, l.Status, func(ctx context.Context) ([]Container, error) {
		if !l.started.Load() {
			return []Container{}, nil
		}

		containers, err := listContainers(ctx, l.runInVM)
		if err == nil {
			force := l.proxyResync.Load()
			l.localhostProxy.sync(publishedTCPPorts(containers), force)
			if force {
				l.proxyResync.Store(false)
			}
		}

		return containers, err
	})
}

// ListImages returns all images, or none when the VM is stopped.
func (l *Lima) ListImages(ctx context.Context) ([]Image, error) {
	return emptyIfStopped(ctx, l.Status, func(ctx context.Context) ([]Image, error) {
		return listImages(ctx, l.runInVM)
	})
}

// ImageHistory returns build layers for the given image reference.
func (l *Lima) ImageHistory(ctx context.Context, ref string) ([]ImageLayer, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	return imageHistory(ctx, l.runInVM, ref)
}

// ListVolumes returns all volumes with in-use enrichment, or none when stopped.
func (l *Lima) ListVolumes(ctx context.Context) ([]Volume, error) {
	return emptyIfStopped(ctx, l.Status, func(ctx context.Context) ([]Volume, error) {
		volumes, err := listVolumes(ctx, l.runInVM)
		if err != nil {
			return nil, err
		}

		return enrichVolumesInUse(ctx, l.runInVM, volumes)
	})
}

// ListNetworks returns all networks, or none when the VM is stopped.
func (l *Lima) ListNetworks(ctx context.Context) ([]Network, error) {
	return emptyIfStopped(ctx, l.Status, func(ctx context.Context) ([]Network, error) {
		return listNetworks(ctx, l.runInVM)
	})
}

// InspectNetwork returns detailed metadata for a network by name.
func (l *Lima) InspectNetwork(ctx context.Context, name string) (NetworkDetail, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return NetworkDetail{}, err
	}

	return inspectNetwork(ctx, l.runInVM, name)
}

// RemoveNetwork deletes a network by name inside the VM.
func (l *Lima) RemoveNetwork(ctx context.Context, name string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return removeNetwork(ctx, l.runInVM, name)
}

// ApplyProxy stores proxy settings and applies them inside the VM when running.
func (l *Lima) ApplyProxy(ctx context.Context, proxy ProxyConfig) error {
	l.mu.Lock()
	l.proxy = proxy
	l.mu.Unlock()

	if err := requireRunning(ctx, l.Status); err != nil {
		return nil
	}

	return applyProxyInVM(ctx, l.runInVM, proxy)
}

// watchPortProxies periodically resyncs localhost proxies with published container ports.
func (l *Lima) watchPortProxies(ctx context.Context) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			status, err := l.Status(ctx)
			if err != nil || status.State != StateRunning || !l.started.Load() {
				continue
			}

			containers, err := listContainers(ctx, l.runInVM)
			if err != nil {
				l.proxyResync.Store(true)
				continue
			}

			force := l.proxyResync.Load()
			l.localhostProxy.sync(publishedTCPPorts(containers), force)
			if force {
				l.proxyResync.Store(false)
			}
		}
	}
}

// CreateVolume creates a named volume in the VM, or anonymous when name is empty.
func (l *Lima) CreateVolume(ctx context.Context, name string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	args := []string{"volume", "create"}
	if name != "" {
		args = append(args, name)
	}

	_, err := l.runInVM(ctx, "nerdctl", args...)
	return err
}

// CloneVolume copies data from source into a new dest volume in the VM.
func (l *Lima) CloneVolume(ctx context.Context, source, dest string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return cloneVolume(ctx, l.runInVM, source, dest)
}

// ExportVolume archives a volume to the destination described by opts.
func (l *Lima) ExportVolume(ctx context.Context, opts VolumeExportOptions) (string, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return "", err
	}

	return RunVolumeExport(ctx, l.runInVM, opts)
}

// RemoveVolume deletes a volume by name in the VM.
func (l *Lima) RemoveVolume(ctx context.Context, name string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "volume", "rm", name)
	return err
}

// InspectVolume returns detailed metadata for a volume by name.
func (l *Lima) InspectVolume(ctx context.Context, name string) (VolumeDetail, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return VolumeDetail{}, err
	}

	return inspectVolume(ctx, l.runInVM, name)
}

// ListVolumeFiles lists directory entries inside a volume at path.
func (l *Lima) ListVolumeFiles(ctx context.Context, name, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	return listVolumeFiles(ctx, l.runInVM, name, path)
}

// VolumeContainers lists containers in the VM that mount the named volume.
func (l *Lima) VolumeContainers(ctx context.Context, name string) ([]VolumeContainerUsage, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	return volumeContainerUsages(ctx, l.runInVM, name)
}

// RunBuild builds an image inside the VM and returns parsed build output.
func (l *Lima) RunBuild(ctx context.Context, contextPath, tag, dockerfile, platform string) (BuildResult, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return BuildResult{}, err
	}

	return runBuild(ctx, l.runInVM, contextPath, tag, dockerfile, platform)
}

// StartContainer starts a stopped container by ID in the VM.
func (l *Lima) StartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "start", id)
	return err
}

// StopContainer stops a running container by ID in the VM.
func (l *Lima) StopContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "stop", id)
	return err
}

// RemoveContainer force-removes a container by ID in the VM.
func (l *Lima) RemoveContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "rm", "-f", id)
	return err
}

// RemoveImage deletes an image by reference in the VM.
func (l *Lima) RemoveImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "rmi", ref)
	return err
}

// PullImage downloads an image from a registry into the VM.
func (l *Lima) PullImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "pull", ref)
	return err
}

// PushImage uploads an image from the VM to a registry.
func (l *Lima) PushImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return pushImage(ctx, l.runInVM, ref)
}

// RunImage starts a detached container from ref in the VM and returns its ID.
func (l *Lima) RunImage(ctx context.Context, ref string) (string, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return "", err
	}

	return runImage(ctx, l.runInVM, ref)
}

// StreamLogs tails recent history then follows new log lines for a container.
func (l *Lima) StreamLogs(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	history, err := l.runInVM(ctx, "nerdctl", "logs", "--tail", logTailLines, id)
	if err == nil {
		emitLogLines(output, history)
	}

	return l.streamLogsFollow(ctx, id, logsFollowSince(), output)
}

// StreamLogsFollow streams only new log lines from the current time onward.
func (l *Lima) StreamLogsFollow(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return l.streamLogsFollow(ctx, id, logsFollowSince(), output)
}

// streamLogsFollow runs nerdctl logs -f inside the VM and pipes lines to output.
func (l *Lima) streamLogsFollow(ctx context.Context, id, since string, output func(string)) error {
	command := exec.CommandContext(ctx, "limactl", append([]string{"shell", l.vmName, "--"}, vmCommand("nerdctl", "logs", "-f", "--since", since, id)...)...)
	command.Env = limaShellEnv()
	return streamCommandLogs(ctx, command, output)
}

// InspectContainer returns raw nerdctl inspect JSON for a container in the VM.
func (l *Lima) InspectContainer(ctx context.Context, id string) (json.RawMessage, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	return inspectContainer(ctx, l.runInVM, id)
}

// ContainerMounts parses mount points from container inspect data.
func (l *Lima) ContainerMounts(ctx context.Context, id string) ([]ContainerMount, error) {
	inspect, err := l.InspectContainer(ctx, id)
	if err != nil {
		return nil, err
	}

	return parseContainerMounts(inspect)
}

// ListContainerFiles lists directory entries inside a container at path.
func (l *Lima) ListContainerFiles(ctx context.Context, id, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	if !isValidContainerPath(path) {
		return nil, fmt.Errorf("invalid path")
	}

	return listContainerFiles(ctx, l.runInVM, id, path)
}

// ExecContainer runs a one-shot command inside a container and returns stdout.
func (l *Lima) ExecContainer(ctx context.Context, id, command string) (string, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return "", err
	}

	return execInContainer(ctx, l.runInVM, id, command)
}

// AttachExec opens an interactive PTY session inside a container in the VM.
func (l *Lima) AttachExec(ctx context.Context, id string, stdin io.Reader, onOutput func([]byte), resizeCh <-chan ExecResize) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	shellArgs := append([]string{"shell", l.vmName, "--"}, vmCommand("nerdctl", interactiveExecArgs(id)...)...)
	command := exec.CommandContext(ctx, "limactl", shellArgs...)
	return attachExecInContainer(ctx, command, stdin, onOutput, resizeCh)
}

// ContainerStats returns CPU and memory usage for a running container.
func (l *Lima) ContainerStats(ctx context.Context, id string) (ContainerStats, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return ContainerStats{}, err
	}

	return containerStats(ctx, l.runInVM, id)
}

// RestartContainer stops and starts a container by ID in the VM.
func (l *Lima) RestartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return restartContainer(ctx, l.runInVM, id)
}

// runInVM executes a command inside the Lima VM via limactl shell.
func (l *Lima) runInVM(ctx context.Context, command string, args ...string) ([]byte, error) {
	shellArgs := append([]string{"shell", l.vmName, "--"}, vmCommand(command, args...)...)
	return runCommandWithRetry(ctx, defaultCommandRetries, defaultCommandRetryDelay, "", "limactl", shellArgs...)
}

// runInVMWithStdin executes a command inside the VM with stdin via limactl shell.
func (l *Lima) runInVMWithStdin(ctx context.Context, stdin, command string, args ...string) ([]byte, error) {
	shellArgs := append([]string{"shell", l.vmName, "--"}, vmCommand(command, args...)...)
	return runCommandWithRetry(ctx, defaultCommandRetries, defaultCommandRetryDelay, stdin, "limactl", shellArgs...)
}

// RegistryStatus reports whether the VM root user is logged in to the default registry.
func (l *Lima) RegistryStatus(ctx context.Context) (RegistryStatus, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return RegistryStatus{Server: defaultRegistryServer}, nil
	}

	output, err := l.runInVM(ctx, "sudo", "cat", "/root/.docker/config.json")
	if err != nil {
		return RegistryStatus{Server: defaultRegistryServer}, nil
	}

	return RegistryStatusFromConfig(output), nil
}

// RegistryLogin authenticates to a container registry inside the VM.
func (l *Lima) RegistryLogin(ctx context.Context, server, username, password string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return registryLogin(ctx, l.runInVM, l.runInVMWithStdin, server, username, password)
}

// RegistryLogout removes stored registry credentials inside the VM.
func (l *Lima) RegistryLogout(ctx context.Context, server string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return registryLogout(ctx, l.runInVM, server)
}

// vmCommand routes commands for the Lima VM. "nerdctl" is transparently
// redirected to "docker" because the VM runs Docker Engine — containers
// live in its moby namespace, not containerd's default namespace.
func vmCommand(command string, args ...string) []string {
	if command == "nerdctl" {
		return append([]string{"sudo", "docker"}, args...)
	}

	return append([]string{command}, args...)
}

// limaShellEnv returns environment variables for limactl shell SSH sessions.
func limaShellEnv() []string {
	return append(os.Environ(), "SSH=ssh -o ControlMaster=no -o ControlPath=none")
}

// waitForNerdctl blocks until nerdctl info succeeds inside the VM or times out.
func (l *Lima) waitForNerdctl(ctx context.Context) error {
	deadline := time.Now().Add(10 * time.Minute)
	for time.Now().Before(deadline) {
		_, err := runCommandOnce(ctx, "", "limactl", "shell", l.vmName, "--", "sudo", NerdctlBin, "info")
		if err == nil {
			return nil
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Second):
		}
	}

	return fmt.Errorf("nerdctl not ready in VM %q", l.vmName)
}

// instanceExists reports whether the configured Lima VM instance already exists.
func (l *Lima) instanceExists(ctx context.Context) (bool, error) {
	output, err := runCommand(ctx, "limactl", "list", "--format", "{{.Name}}")
	if err != nil {
		return false, err
	}

	for _, name := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		if name == l.vmName {
			return true, nil
		}
	}

	return false, nil
}

// ensureTemplate writes the rendered lima.yaml template to the config directory.
func (l *Lima) ensureTemplate() error {
	path, err := l.templateFile()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Join(filepath.Dir(path), "mounts"), 0o755); err != nil {
		return err
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}

	diskGB := l.diskGB
	if diskGB <= 0 {
		diskGB = 100
	}

	l.mu.Lock()
	currentProxy := l.proxy
	l.mu.Unlock()

	content := fmt.Sprintf(limaTemplate, home, home, l.cpus, l.memoryGB, l.memorySwapGB, diskGB, currentProxy.HTTPProxy, currentProxy.HTTPSProxy, currentProxy.NoProxy)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		return err
	}

	l.templatePath = path
	return nil
}

// templateFile returns the path to the generated lima.yaml in the config dir.
func (l *Lima) templateFile() (string, error) {
	configDir, err := configDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(configDir, "lima.yaml"), nil
}

// configDir returns ~/.config/calf, creating the path components as needed.
func configDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(home, ".config", "calf"), nil
}

// defaultDockerSocket returns the default Calf Docker socket path under ~/.config/calf.
func defaultDockerSocket() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}

	return filepath.Join(home, ".config", "calf", "docker.sock")
}

// dockerCLISocketPath returns ~/.docker/run/docker.sock used by the Docker CLI.
func dockerCLISocketPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}

	return filepath.Join(home, ".docker", "run", "docker.sock")
}

// ensureDockerCLISocket listens on the Calf socket and symlinks the Docker CLI path.
func (l *Lima) ensureDockerCLISocket() error {
	if l.dockerSocket == "" {
		return nil
	}

	dir := filepath.Dir(l.dockerSocket)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create %s: %w", dir, err)
	}

	os.Remove(l.dockerSocket)

	listener, err := net.Listen("unix", l.dockerSocket)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", l.dockerSocket, err)
	}

	l.mu.Lock()
	l.proxyListener = listener
	l.mu.Unlock()

	dockerCliPath := dockerCLISocketPath()
	if dockerCliPath != "" {
		os.MkdirAll(filepath.Dir(dockerCliPath), 0o755)
		os.Remove(dockerCliPath)
		if err := os.Symlink(l.dockerSocket, dockerCliPath); err != nil {
			limaLogger.Warn("failed to create Docker CLI symlink", "path", dockerCliPath, "error", err)
		}
	}

	go l.serveTCPProxy()

	return nil
}

// serveTCPProxy forwards HTTP requests from the unix socket to the VM Docker API.
func (l *Lima) serveTCPProxy() {
	targetURL, err := url.Parse("http://127.0.0.1:2375")
	if err != nil {
		limaLogger.Warn("docker HTTP proxy: invalid target URL", "error", err)
		return
	}

	proxy := httputil.NewSingleHostReverseProxy(targetURL)
	proxy.ErrorLog = slog.NewLogLogger(slog.NewTextHandler(io.Discard, nil), slog.LevelError)
	proxy.Transport = &http.Transport{
		DialContext: (&net.Dialer{Timeout: 5 * time.Second}).DialContext,
	}

	server := &http.Server{Handler: proxy}

	l.mu.Lock()
	l.dockerProxy = server
	listener := l.proxyListener
	l.mu.Unlock()

	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		limaLogger.Warn("docker HTTP proxy: serve error", "error", err)
	}
}

// removeDockerCLISocket stops the proxy server and removes socket files.
func (l *Lima) removeDockerCLISocket() {
	l.mu.Lock()
	server := l.dockerProxy
	listener := l.proxyListener
	l.dockerProxy = nil
	l.proxyListener = nil
	l.mu.Unlock()

	if server != nil {
		server.Close()
	}
	if listener != nil {
		listener.Close()
	}

	os.Remove(l.dockerSocket)

	dockerCliPath := dockerCLISocketPath()
	if dockerCliPath != "" {
		os.Remove(dockerCliPath)
	}
}
