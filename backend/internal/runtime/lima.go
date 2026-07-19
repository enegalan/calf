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

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/limavm"
)

// limaLogger is the logger for the Lima runtime.
var limaLogger = slog.Default()

//go:embed lima.yaml
var limaTemplate string

// Lima represents a Lima VM runtime.
type Lima struct {
	mu      sync.Mutex
	startMu sync.Mutex

	vmName         string
	dockerSocket   string
	templatePath   string
	cpus           int
	memoryGB       int
	memorySwapGB   int
	diskGB         int
	vmKeepAlive    bool
	proxy          ProxyConfig
	started        atomic.Bool
	shellReady     atomic.Bool
	proxyResync    atomic.Bool
	lastState      State
	localhostProxy *localhostProxies
	ownerCtx       context.Context
	watcherCancel  context.CancelFunc
	proxyListener  net.Listener
	dockerProxy    *http.Server
}

// NewLima constructs a Lima VM runtime with resource limits and proxy settings.
func NewLima(vmName string, dockerSocket string, cpus int, memoryGB int, memorySwapGB int, diskGB int, apiListenPort int, vmKeepAlive bool, proxy ProxyConfig) *Lima {
	if vmName == "" {
		vmName = constants.DefaultVMName
	}

	if dockerSocket == "" {
		dockerSocket = config.DefaultDockerSocketPath()
	}

	lima := &Lima{
		vmName:         vmName,
		dockerSocket:   dockerSocket,
		cpus:           cpus,
		memoryGB:       memoryGB,
		memorySwapGB:   memorySwapGB,
		diskGB:         diskGB,
		vmKeepAlive:    vmKeepAlive,
		proxy:          proxy,
		ownerCtx:       context.Background(),
		localhostProxy: newLocalhostProxies(),
	}
	lima.localhostProxy.setReservedPorts(apiListenPort)

	return lima
}

// DockerSocket returns the path to the Docker-compatible socket on the host.
func (l *Lima) DockerSocket() string {
	return l.dockerSocket
}

// Start creates or boots the Lima VM, waits for the Docker API, and starts port proxies.
// Concurrent and repeat calls are single-flight and idempotent when the host socket is already up.
func (l *Lima) Start(ctx context.Context) error {
	l.startMu.Lock()
	defer l.startMu.Unlock()

	if _, err := exec.LookPath("limactl"); err != nil {
		return fmt.Errorf("limactl not found: install Lima first")
	}

	if err := l.ensureTemplate(); err != nil {
		return err
	}

	if l.hostSetupReady() {
		running, err := l.vmIsRunning(ctx)
		if err != nil {
			return err
		}
		if running && l.dockerAPIReady(ctx) {
			return nil
		}
	}

	if err := l.ensureDockerCLISocket(); err != nil {
		limaLogger.Warn("failed to set up Docker CLI socket (non-fatal)", "error", err)
	}

	lifeCtx := l.resetLifecycle()

	running, err := l.vmIsRunning(ctx)
	if err != nil {
		return err
	}

	if running {
		l.shellReady.Store(true)
	} else {
		if err := l.startVMUntilDockerReady(ctx); err != nil {
			return err
		}
	}

	if err := l.waitForDockerAPI(ctx); err != nil {
		return err
	}

	l.ensureBuildxAsync(lifeCtx)

	if l.proxy != (ProxyConfig{}) {
		proxy := l.proxy
		go func() {
			applyCtx, cancel := context.WithTimeout(lifeCtx, constants.DefaultActionTimeout)
			defer cancel()
			if err := l.ApplyProxy(applyCtx, proxy); err != nil {
				if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
					return
				}
				limaLogger.Warn("proxy application during start failed (non-fatal)", "error", err)
			}
		}()
	}

	l.syncStartAtLogin(ctx)
	l.markStarted(lifeCtx)
	return nil
}

// startVMUntilDockerReady starts the Lima instance and returns as soon as the Docker API answers.
// limactl start may still be finishing SSH/boot-script gates in the background; shell ops wait via waitForShellReady.
func (l *Lima) startVMUntilDockerReady(ctx context.Context) error {
	exists, err := l.instanceExists(ctx)
	if err != nil {
		return err
	}
	if !exists {
		if _, err := runCommand(ctx, "limactl", "create", "--name", l.vmName, l.templatePath); err != nil {
			return err
		}
	}

	l.shellReady.Store(false)
	errCh := make(chan error, 1)
	go func() {
		_, startErr := runCommandWithRetry(ctx, constants.DefaultCommandRetries, constants.DefaultCommandRetryDelay, "", "limactl", "start", l.vmName)
		if startErr == nil {
			l.shellReady.Store(true)
		}
		errCh <- startErr
	}()

	dockerErrCh := make(chan error, 1)
	go func() {
		dockerErrCh <- l.waitForDockerAPI(ctx)
	}()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case startErr := <-errCh:
		if startErr != nil {
			return startErr
		}
		return nil
	case dockerErr := <-dockerErrCh:
		if dockerErr != nil {
			select {
			case startErr := <-errCh:
				if startErr != nil {
					return startErr
				}
			case <-ctx.Done():
				return ctx.Err()
			}
			return dockerErr
		}
		go func() {
			if startErr := <-errCh; startErr != nil {
				limaLogger.Warn("limactl start failed after Docker API was ready", "error", startErr)
				l.shellReady.Store(false)
			}
		}()
		return nil
	}
}

// waitForShellReady blocks until limactl start has finished (SSH/shell usable) or ctx ends.
func (l *Lima) waitForShellReady(ctx context.Context) error {
	if l.shellReady.Load() {
		return nil
	}
	deadline := time.Now().Add(10 * time.Minute)
	delay := constants.DockerAPIReadyPollBase
	for time.Now().Before(deadline) {
		if l.shellReady.Load() {
			return nil
		}
		if running, err := l.vmIsRunning(ctx); err == nil && running {
			// Instance already Running; limactl shell works even if our start goroutine has not flipped the flag yet.
			l.shellReady.Store(true)
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
	return fmt.Errorf("lima shell not ready for VM %q", l.vmName)
}

// hostSetupReady reports whether Start already brought up the host Docker socket proxy.
func (l *Lima) hostSetupReady() bool {
	if !l.started.Load() {
		return false
	}
	l.mu.Lock()
	listener := l.proxyListener
	l.mu.Unlock()
	if listener == nil {
		return false
	}
	if l.dockerSocket == "" {
		return true
	}
	_, err := os.Stat(l.dockerSocket)
	return err == nil
}

// SetOwnerContext sets the parent context for Lima background work (watchers, Buildx, proxy).
// Canceled when the daemon shuts down so handler-triggered Start recovery stays cancellable.
func (l *Lima) SetOwnerContext(ctx context.Context) {
	if ctx == nil {
		ctx = context.Background()
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.ownerCtx = ctx
}

// resetLifecycle cancels prior background work and returns a fresh lifecycle context.
func (l *Lima) resetLifecycle() context.Context {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.watcherCancel != nil {
		l.watcherCancel()
		l.watcherCancel = nil
	}
	parent := l.ownerCtx
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithCancel(parent)
	l.watcherCancel = cancel
	return ctx
}

// markStarted records a running runtime and starts background port-proxy maintenance.
func (l *Lima) markStarted(lifeCtx context.Context) {
	l.started.Store(true)
	go l.watchPortProxies(lifeCtx)
}

// vmIsRunning reports whether the Lima instance exists and is in the Running state.
func (l *Lima) vmIsRunning(ctx context.Context) (bool, error) {
	status, err := l.limaVMStatus(ctx)
	if err != nil {
		return false, err
	}

	return strings.EqualFold(status, "Running"), nil
}

// Stop tears down proxies and stops the Lima VM instance.
func (l *Lima) Stop(ctx context.Context) error {
	if _, err := exec.LookPath("limactl"); err != nil {
		return fmt.Errorf("limactl not found: install Lima first")
	}

	// Always release host resources first so a missing or externally removed VM
	// does not leave watchers, localhost proxies, or the Docker CLI socket behind.
	l.mu.Lock()
	if l.watcherCancel != nil {
		l.watcherCancel()
		l.watcherCancel = nil
	}
	l.mu.Unlock()

	l.localhostProxy.stopAll()
	l.removeDockerCLISocket()
	l.started.Store(false)
	l.shellReady.Store(false)

	exists, err := l.instanceExists(ctx)
	if err != nil {
		return err
	}

	if !exists {
		return nil
	}

	if l.vmKeepAlive {
		return nil
	}

	l.disableStartAtLogin(ctx)

	status, err := l.limaVMStatus(ctx)
	if err != nil {
		if isIgnorableLimaStopError(err) {
			return nil
		}
		return err
	}
	if status == "" || strings.EqualFold(status, "Stopped") {
		return nil
	}

	_, err = runCommand(ctx, "limactl", "stop", l.vmName)
	if isIgnorableLimaStopError(err) {
		return nil
	}
	return err
}

// ensureBuildxAsync bootstraps buildx off the Start critical path.
func (l *Lima) ensureBuildxAsync(lifeCtx context.Context) {
	go func() {
		buildxCtx, cancel := context.WithTimeout(lifeCtx, constants.DefaultActionTimeout)
		defer cancel()
		if err := ensureBuildx(buildxCtx, l.runInVM); err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				return
			}
			limaLogger.Warn("buildx setup failed (non-fatal)", "error", err)
		}
	}()
}

// syncStartAtLogin enables or disables Lima login autostart to match vm_keep_alive.
func (l *Lima) syncStartAtLogin(ctx context.Context) {
	if l.vmKeepAlive {
		l.enableStartAtLogin(ctx)
		return
	}
	l.disableStartAtLogin(ctx)
}

// enableStartAtLogin registers the Lima instance to start when the user logs in.
func (l *Lima) enableStartAtLogin(ctx context.Context) {
	if _, err := runCommand(ctx, "limactl", "start-at-login", "--enabled", l.vmName); err != nil {
		limaLogger.Warn("failed to enable Lima start-at-login (non-fatal)", "error", err, "vm", l.vmName)
	}
}

// disableStartAtLogin unregisters Lima login autostart for the instance.
func (l *Lima) disableStartAtLogin(ctx context.Context) {
	if _, err := runCommand(ctx, "limactl", "start-at-login", "--enabled=false", l.vmName); err != nil {
		limaLogger.Warn("failed to disable Lima start-at-login (non-fatal)", "error", err, "vm", l.vmName)
	}
}

// limaVMStatus returns the limactl status string for the configured VM instance.
func (l *Lima) limaVMStatus(ctx context.Context) (string, error) {
	output, err := runCommand(ctx, "limactl", "list", "--format", "{{.Status}}", l.vmName)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

// isIgnorableLimaStopError reports whether Stop can ignore a limactl stop failure during shutdown.
func isIgnorableLimaStopError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	return strings.Contains(strings.ToLower(err.Error()), "expected status")
}

// Status reports VM mode, running state, socket health, and port conflicts.
func (l *Lima) Status(ctx context.Context) (Status, error) {
	status := Status{
		Mode:         Mode(constants.RuntimeModeVM),
		State:        State(constants.RuntimeStateStopped),
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
			status.State = State(constants.RuntimeStateRunning)
		} else {
			limaLogger.Warn("vm not running", "vm", l.vmName, "status", fields[1])
		}
	}

	if !found {
		status.Log = "VM not found in limactl list"
	}

	if status.State == State(constants.RuntimeStateRunning) && l.dockerSocket != "" {
		conn, err := net.DialTimeout("unix", l.dockerSocket, 100*time.Millisecond)
		if err != nil {
			if isTransientSocketDialError(err) {
				limaLogger.Debug("socket not ready yet (expected during startup)", "socket", l.dockerSocket, "error", err)
			} else {
				limaLogger.Warn("socket dial failed", "socket", l.dockerSocket, "error", err)
			}
			// Fall back to TCP on port 2375 (via Lima port forward + socat inside VM)
			tcpConn, tcpErr := net.DialTimeout("tcp", "127.0.0.1:2375", 100*time.Millisecond)
			if tcpErr != nil {
				if isTransientSocketDialError(tcpErr) {
					limaLogger.Debug("docker tcp proxy not ready yet (expected during startup)", "error", tcpErr)
				} else {
					limaLogger.Warn("tcp fallback also failed", "error", tcpErr)
				}
				if !isTransientSocketDialError(err) && !isTransientSocketDialError(tcpErr) {
					status.State = State(constants.RuntimeStateStopped)
					status.Log = fmt.Sprintf("socket dial failed: %v", err)
				}
			} else {
				tcpConn.Close()
			}
		} else {
			conn.Close()
		}
	}

	l.mu.Lock()
	if status.State == State(constants.RuntimeStateRunning) && l.lastState != State(constants.RuntimeStateRunning) {
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
		return err
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
			if err != nil || status.State != State(constants.RuntimeStateRunning) || !l.started.Load() {
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

// RunBuild builds an image inside the VM with buildx and returns parsed build output.
func (l *Lima) RunBuild(ctx context.Context, contextPath, tag, dockerfile, platform string) (BuildResult, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return BuildResult{}, err
	}

	result, err := runBuildx(ctx, l.runInVM, contextPath, tag, dockerfile, platform)
	if err != nil && isBuildxMissingError(err) {
		limaLogger.Warn("buildx build failed; falling back to docker build", "error", err)
		return runBuild(ctx, l.runInVM, contextPath, tag, dockerfile, platform)
	}
	return result, err
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
	command := exec.CommandContext(ctx, "limactl", append([]string{"shell", l.vmName, "--"}, NerdctlVMArgs("logs", "-f", "--since", since, id)...)...)
	command.Env = limavm.ShellEnv()
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

	shellArgs := append([]string{"shell", l.vmName, "--"}, NerdctlVMArgs(interactiveExecArgs(id)...)...)
	command := exec.CommandContext(ctx, "limactl", shellArgs...)
	command.Env = limavm.ShellEnv()
	return attachContainerExec(ctx, command, stdin, onOutput, resizeCh)
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
	if err := l.waitForShellReady(ctx); err != nil {
		return nil, err
	}
	shellArgs := append([]string{"shell", l.vmName, "--"}, limaVMCommand(command, args...)...)
	return runCommandWithRetryEnv(ctx, constants.DefaultCommandRetries, constants.DefaultCommandRetryDelay, limavm.ShellEnv(), "", "limactl", shellArgs...)
}

// runInVMWithStdin executes a command inside the VM with stdin via limactl shell.
func (l *Lima) runInVMWithStdin(ctx context.Context, stdin, command string, args ...string) ([]byte, error) {
	if err := l.waitForShellReady(ctx); err != nil {
		return nil, err
	}
	shellArgs := append([]string{"shell", l.vmName, "--"}, limaVMCommand(command, args...)...)
	return runCommandWithRetryEnv(ctx, constants.DefaultCommandRetries, constants.DefaultCommandRetryDelay, limavm.ShellEnv(), stdin, "limactl", shellArgs...)
}

// RegistryStatus reports whether the VM root user is logged in to the default registry.
func (l *Lima) RegistryStatus(ctx context.Context) (RegistryStatus, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return RegistryStatus{Server: constants.DefaultRegistryServer}, nil
	}

	output, err := l.runInVM(ctx, "sudo", "cat", "/root/.docker/config.json")
	if err != nil {
		return RegistryStatus{Server: constants.DefaultRegistryServer}, nil
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

// limaVMCommand builds the in-VM command argv for limactl shell.
func limaVMCommand(command string, args ...string) []string {
	if command == "nerdctl" {
		return NerdctlVMArgs(args...)
	}

	return vmCommand(command, args...)
}

// vmCommand builds argv for non-container CLI commands run inside the Lima VM.
func vmCommand(command string, args ...string) []string {
	return append([]string{command}, args...)
}

// isTransientSocketDialError reports whether a dial failure is expected while the docker proxy starts.
func isTransientSocketDialError(err error) bool {
	if errors.Is(err, syscall.ENOENT) {
		return true
	}

	var opErr *net.OpError
	if errors.As(err, &opErr) && errors.Is(opErr.Err, syscall.ECONNREFUSED) {
		return true
	}

	return false
}

// waitForDockerAPI blocks until the Docker HTTP API answers on the Calf socket or Lima port forward.
func (l *Lima) waitForDockerAPI(ctx context.Context) error {
	deadline := time.Now().Add(10 * time.Minute)
	delay := constants.DockerAPIReadyPollBase
	for time.Now().Before(deadline) {
		if l.dockerAPIReady(ctx) {
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

	return fmt.Errorf("docker API not ready in VM %q", l.vmName)
}

// dockerAPIReady reports whether the Docker HTTP API responds to /_ping.
func (l *Lima) dockerAPIReady(ctx context.Context) bool {
	if l.dockerSocket != "" {
		client := &http.Client{
			Timeout: 2 * time.Second,
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					var dialer net.Dialer
					return dialer.DialContext(ctx, "unix", l.dockerSocket)
				},
				DisableKeepAlives: true,
			},
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://localhost/_ping", nil)
		if err == nil {
			resp, err := client.Do(req)
			if err == nil {
				resp.Body.Close()
				return resp.StatusCode == http.StatusOK
			}
		}
	}

	conn, err := (&net.Dialer{Timeout: 500 * time.Millisecond}).DialContext(ctx, "tcp", "127.0.0.1:2375")
	if err != nil {
		return false
	}
	defer conn.Close()

	deadline, ok := ctx.Deadline()
	if !ok {
		deadline = time.Now().Add(500 * time.Millisecond)
	}
	if err := conn.SetDeadline(deadline); err != nil {
		return false
	}

	if _, err := conn.Write([]byte("GET /_ping HTTP/1.0\r\nHost: localhost\r\n\r\n")); err != nil {
		return false
	}

	buf := make([]byte, 64)
	n, err := conn.Read(buf)
	if err != nil {
		return false
	}

	return strings.Contains(string(buf[:n]), "200")
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
	existing, readErr := os.ReadFile(path)
	if readErr != nil || string(existing) != content {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			return err
		}
	}

	if err := patchLegacyLimaCIDATAProvision(l.vmName); err != nil {
		limaLogger.Warn("failed to patch legacy Lima provision script", "error", err)
	}

	l.templatePath = path
	return nil
}

const legacyLimaCIDATAProvision = `      if [ -f /mnt/lima-cidata/lima.env ]; then
        # shellcheck disable=SC1091
        . /mnt/lima-cidata/lima.env
        usermod -aG docker "${LIMA_CIDATA_USER}"
      fi`

const modernLimaUserProvision = `      usermod -aG docker "{{.User}}"`

// patchLegacyLimaCIDATAProvision rewrites deprecated LIMA_CIDATA references in an existing Lima instance config.
func patchLegacyLimaCIDATAProvision(vmName string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}

	path := filepath.Join(home, ".lima", vmName, "lima.yaml")
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}

	content := string(data)
	if !strings.Contains(content, "LIMA_CIDATA") {
		return nil
	}

	if strings.Contains(content, legacyLimaCIDATAProvision) {
		content = strings.Replace(content, legacyLimaCIDATAProvision, modernLimaUserProvision, 1)
	} else {
		content = strings.ReplaceAll(content, `usermod -aG docker "${LIMA_CIDATA_USER}"`, `usermod -aG docker "{{.User}}"`)
	}

	if content == string(data) {
		return nil
	}

	return os.WriteFile(path, []byte(content), 0o644)
}

// templateFile returns the path to the generated lima.yaml in the config dir.
func (l *Lima) templateFile() (string, error) {
	configDir, err := config.ConfigDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(configDir, "lima.yaml"), nil
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
// Reuses an existing healthy listener instead of stacking proxy servers.
func (l *Lima) ensureDockerCLISocket() error {
	if l.dockerSocket == "" {
		return nil
	}

	l.mu.Lock()
	alreadyServing := l.proxyListener != nil
	l.mu.Unlock()
	if alreadyServing {
		if _, err := os.Stat(l.dockerSocket); err == nil {
			return nil
		}
	}

	l.removeDockerCLISocket()

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
