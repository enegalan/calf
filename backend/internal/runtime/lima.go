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

func (l *Lima) DockerSocket() string {
	return l.dockerSocket
}

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

func (l *Lima) ListImages(ctx context.Context) ([]Image, error) {
	return emptyIfStopped(ctx, l.Status, func(ctx context.Context) ([]Image, error) {
		return listImages(ctx, l.runInVM)
	})
}

func (l *Lima) ImageHistory(ctx context.Context, ref string) ([]ImageLayer, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	return imageHistory(ctx, l.runInVM, ref)
}

func (l *Lima) ListVolumes(ctx context.Context) ([]Volume, error) {
	return emptyIfStopped(ctx, l.Status, func(ctx context.Context) ([]Volume, error) {
		volumes, err := listVolumes(ctx, l.runInVM)
		if err != nil {
			return nil, err
		}

		return enrichVolumesInUse(ctx, l.runInVM, volumes)
	})
}

func (l *Lima) ListNetworks(ctx context.Context) ([]Network, error) {
	return emptyIfStopped(ctx, l.Status, func(ctx context.Context) ([]Network, error) {
		return listNetworks(ctx, l.runInVM)
	})
}

func (l *Lima) InspectNetwork(ctx context.Context, name string) (NetworkDetail, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return NetworkDetail{}, err
	}

	return inspectNetwork(ctx, l.runInVM, name)
}

func (l *Lima) RemoveNetwork(ctx context.Context, name string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return removeNetwork(ctx, l.runInVM, name)
}

func (l *Lima) ApplyProxy(ctx context.Context, proxy ProxyConfig) error {
	l.mu.Lock()
	l.proxy = proxy
	l.mu.Unlock()

	if err := requireRunning(ctx, l.Status); err != nil {
		return nil
	}

	return applyProxyInVM(ctx, l.runInVM, proxy)
}

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

func (l *Lima) CloneVolume(ctx context.Context, source, dest string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return cloneVolume(ctx, l.runInVM, source, dest)
}

func (l *Lima) ExportVolume(ctx context.Context, opts VolumeExportOptions) (string, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return "", err
	}

	return RunVolumeExport(ctx, l.runInVM, opts)
}

func (l *Lima) RemoveVolume(ctx context.Context, name string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "volume", "rm", name)
	return err
}

func (l *Lima) InspectVolume(ctx context.Context, name string) (VolumeDetail, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return VolumeDetail{}, err
	}

	return inspectVolume(ctx, l.runInVM, name)
}

func (l *Lima) ListVolumeFiles(ctx context.Context, name, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	return listVolumeFiles(ctx, l.runInVM, name, path)
}

func (l *Lima) VolumeContainers(ctx context.Context, name string) ([]VolumeContainerUsage, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	return volumeContainerUsages(ctx, l.runInVM, name)
}

func (l *Lima) RunBuild(ctx context.Context, contextPath, tag, dockerfile, platform string) (BuildResult, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return BuildResult{}, err
	}

	return runBuild(ctx, l.runInVM, contextPath, tag, dockerfile, platform)
}

func (l *Lima) StartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "start", id)
	return err
}

func (l *Lima) StopContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "stop", id)
	return err
}

func (l *Lima) RemoveContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "rm", "-f", id)
	return err
}

func (l *Lima) RemoveImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "rmi", ref)
	return err
}

func (l *Lima) PullImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "pull", ref)
	return err
}

func (l *Lima) PushImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return pushImage(ctx, l.runInVM, ref)
}

func (l *Lima) RunImage(ctx context.Context, ref string) (string, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return "", err
	}

	return runImage(ctx, l.runInVM, ref)
}

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

func (l *Lima) StreamLogsFollow(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return l.streamLogsFollow(ctx, id, logsFollowSince(), output)
}

func (l *Lima) streamLogsFollow(ctx context.Context, id, since string, output func(string)) error {
	command := exec.CommandContext(ctx, "limactl", append([]string{"shell", l.vmName, "--"}, vmCommand("nerdctl", "logs", "-f", "--since", since, id)...)...)
	command.Env = limaShellEnv()
	return streamCommandLogs(ctx, command, output)
}

func (l *Lima) InspectContainer(ctx context.Context, id string) (json.RawMessage, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	return inspectContainer(ctx, l.runInVM, id)
}

func (l *Lima) ContainerMounts(ctx context.Context, id string) ([]ContainerMount, error) {
	inspect, err := l.InspectContainer(ctx, id)
	if err != nil {
		return nil, err
	}

	return parseContainerMounts(inspect)
}

func (l *Lima) ListContainerFiles(ctx context.Context, id, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	if !isValidContainerPath(path) {
		return nil, fmt.Errorf("invalid path")
	}

	return listContainerFiles(ctx, l.runInVM, id, path)
}

func (l *Lima) ExecContainer(ctx context.Context, id, command string) (string, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return "", err
	}

	return execInContainer(ctx, l.runInVM, id, command)
}

func (l *Lima) AttachExec(ctx context.Context, id string, stdin io.Reader, onOutput func([]byte), resizeCh <-chan ExecResize) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	shellArgs := append([]string{"shell", l.vmName, "--"}, vmCommand("nerdctl", interactiveExecArgs(id)...)...)
	command := exec.CommandContext(ctx, "limactl", shellArgs...)
	return attachExecInContainer(ctx, command, stdin, onOutput, resizeCh)
}

func (l *Lima) ContainerStats(ctx context.Context, id string) (ContainerStats, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return ContainerStats{}, err
	}

	return containerStats(ctx, l.runInVM, id)
}

func (l *Lima) RestartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return restartContainer(ctx, l.runInVM, id)
}

func (l *Lima) runInVM(ctx context.Context, command string, args ...string) ([]byte, error) {
	shellArgs := append([]string{"shell", l.vmName, "--"}, vmCommand(command, args...)...)
	return runCommandWithRetry(ctx, defaultCommandRetries, defaultCommandRetryDelay, "", "limactl", shellArgs...)
}

func (l *Lima) runInVMWithStdin(ctx context.Context, stdin, command string, args ...string) ([]byte, error) {
	shellArgs := append([]string{"shell", l.vmName, "--"}, vmCommand(command, args...)...)
	return runCommandWithRetry(ctx, defaultCommandRetries, defaultCommandRetryDelay, stdin, "limactl", shellArgs...)
}

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

func (l *Lima) RegistryLogin(ctx context.Context, server, username, password string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return registryLogin(ctx, l.runInVM, l.runInVMWithStdin, server, username, password)
}

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

func limaShellEnv() []string {
	return append(os.Environ(), "SSH=ssh -o ControlMaster=no -o ControlPath=none")
}

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

func (l *Lima) templateFile() (string, error) {
	configDir, err := configDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(configDir, "lima.yaml"), nil
}

func configDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(home, ".config", "calf"), nil
}

func defaultDockerSocket() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}

	return filepath.Join(home, ".config", "calf", "docker.sock")
}

func dockerCLISocketPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}

	return filepath.Join(home, ".docker", "run", "docker.sock")
}

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
