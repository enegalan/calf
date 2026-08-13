//go:build darwin

package runtime

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
)

var guestLogger = slog.Default()

// Guest holds shared macOS guest state (disk, EFI, vsock Docker helpers) used by Krunkit. It
// embeds cliOps for the operations shared with Native (see cli_ops.go); methods with
// guest-specific behavior are defined below.
type Guest struct {
	cliOps
	mu             sync.Mutex
	vmName         string
	dockerSocket   string // public CLI path (~/.config/calf/docker.sock); daemon wake-proxy listens here
	engineSocket   string // krunkit vsock path under guest data dir
	cpus           int
	memoryGB       int
	diskGB         int
	diskImage      string
	vmKeepAlive    bool
	proxy          ProxyConfig
	dataDir        string
	started        atomic.Bool
	proxyResync    atomic.Bool
	cmd            *exec.Cmd
	localhostProxy *localhostProxies
	ownerCtx       context.Context
	watcherCancel  context.CancelFunc

	listMu            sync.Mutex
	listCache         []Container
	listCacheAt       time.Time
	listInflight      chan struct{}
	listInflightErr   error
	listInflightValue []Container
}

// NewGuest constructs shared guest helpers for the macOS krunkit runtime.
func NewGuest(vmName, dockerSocket string, cpus, memoryGB, _, diskGB int, diskImage string, apiListenPort int, vmKeepAlive bool, proxy ProxyConfig) *Guest {
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
	if diskGB < 1 {
		diskGB = 100
	}
	if override := os.Getenv("CALF_GUEST_MEMORY_GB"); override != "" {
		if n, err := strconv.Atoi(override); err == nil && n > 0 {
			memoryGB = n
		}
	}
	dataDir := filepath.Join(home, ".config", "calf", "guest", vmName)
	resolvedDisk := strings.TrimSpace(diskImage)
	if resolvedDisk == "" {
		resolvedDisk = filepath.Join(dataDir, "disk.raw")
	}
	v := &Guest{
		vmName:         vmName,
		dockerSocket:   dockerSocket,
		engineSocket:   filepath.Join(dataDir, "docker-engine.sock"),
		cpus:           cpus,
		memoryGB:       memoryGB,
		diskGB:         diskGB,
		diskImage:      resolvedDisk,
		vmKeepAlive:    vmKeepAlive,
		proxy:          proxy,
		dataDir:        dataDir,
		localhostProxy: newLocalhostProxies(),
		ownerCtx:       context.Background(),
	}
	v.localhostProxy.setReservedPorts(apiListenPort)
	v.cliOps = cliOps{status: v.Status, runLocal: v.runLocal, runLocalWithStdin: v.runLocalWithStdin}
	return v
}

// DockerSocket returns the public host path the Docker CLI should use (daemon wake-proxy).
func (v *Guest) DockerSocket() string { return v.dockerSocket }

// EngineDockerSocket returns the krunkit vsock-backed socket path (not the public CLI path).
func (v *Guest) EngineDockerSocket() string { return v.engineSocket }

func (v *Guest) diskPath() string { return v.diskImage }
func (v *Guest) efiPath() string  { return filepath.Join(v.dataDir, "efi-store") }

// resolveSeedArchive returns a compressed guest disk path used for first-run extract.
func resolveSeedArchive(dataDir string) string {
	if override := strings.TrimSpace(os.Getenv("CALF_GUEST_DISK_ZST")); override != "" {
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
			filepath.Join(dir, "..", "Resources", "guest-disk.raw.zst"),
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
func (v *Guest) ensureGuestDisk(ctx context.Context) error {
	if _, err := os.Stat(v.diskPath()); err == nil {
		return nil
	}
	if err := os.MkdirAll(v.dataDir, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(v.diskPath()), 0o755); err != nil {
		return err
	}
	seed := resolveSeedArchive(v.dataDir)
	if seed == "" {
		dlCtx, cancel := context.WithTimeout(ctx, constants.GuestDiskFetchTimeout)
		defer cancel()
		downloaded, err := v.downloadGuestDisk(dlCtx)
		if err != nil {
			return fmt.Errorf("guest disk missing at %s (%w); run make guest-disk or set CALF_GUEST_DISK_URL", v.diskPath(), err)
		}
		seed = downloaded
	}
	if err := ensureHostSpaceForGuestExtract(v.dataDir, seed); err != nil {
		return err
	}
	return v.extractGuestSeed(seed)
}

// ensureHostMountSymlink makes host ~/.config/calf/mounts resolve inside the guest via /mnt/calf.
// Skipped when $HOME is already the calf-home virtiofs share (see ensureHostHomeShare).
func (v *Guest) ensureHostMountSymlink(ctx context.Context) {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return
	}
	hostMounts := filepath.Join(home, ".config", "calf", "mounts")
	script := "mkdir -p /mnt/calf && mkdir -p \"/host" + filepath.Dir(hostMounts) + "\" && " +
		"if [ -L \"/host" + home + "\" ] && [ \"$(readlink \"/host" + home + "\")\" = \"/mnt/calf-home\" ]; then exit 0; fi && " +
		"ln -sfn /mnt/calf \"/host" + hostMounts + "\""
	_, _ = v.runLocal(ctx, "docker", "run", "--rm", "--privileged", "-v", "/:/host", "alpine:3.20", "sh", "-c", script)
}

// runGuestRoot runs a shell script in the guest init mount/network namespace.
func (v *Guest) runGuestRoot(ctx context.Context, script string) ([]byte, error) {
	return v.runLocal(ctx, "docker", "run", "--rm", "--privileged", "--pid=host",
		"alpine:3.20", "nsenter", "-t", "1", "-m", "-u", "-i", "-n", "--", "bash", "-lc", script)
}

// guestCommandRunner adapts guest root shells and docker CLI for shared helpers (proxy, buildx install).
func (v *Guest) guestCommandRunner(ctx context.Context, command string, args ...string) ([]byte, error) {
	if command == "nerdctl" || command == "docker" {
		return v.runLocal(ctx, command, args...)
	}
	if command == "bash" && len(args) >= 2 && args[0] == "-lc" {
		return v.runGuestRoot(ctx, args[1])
	}
	if command == "sudo" && len(args) >= 1 {
		joined := strings.Join(args, " ")
		return v.runGuestRoot(ctx, joined)
	}
	all := append([]string{command}, args...)
	return v.runGuestRoot(ctx, strings.Join(all, " "))
}

// ensureHostDockerInternal maps host.docker.internal to the guest NAT gateway for containers.
// Fast path only: never apt-get or restart Docker on Start (cold-start critical).
func (v *Guest) ensureHostDockerInternal(ctx context.Context) {
	script := `
set -e
GW=$(ip -4 route show default | awk '{print $3; exit}')
if [ -z "$GW" ]; then
  exit 1
fi
if grep -qE "address=/host\\.docker\\.internal/${GW}$" /etc/dnsmasq.d/calf-host.conf 2>/dev/null \
  && grep -qE "^${GW}[[:space:]]+host\\.docker\\.internal$" /etc/hosts 2>/dev/null; then
  exit 0
fi
if grep -qE '[[:space:]]host\.docker\.internal$' /etc/hosts 2>/dev/null; then
  sed -i -E '/[[:space:]]host\.docker\.internal$/d' /etc/hosts
fi
echo "$GW host.docker.internal" >> /etc/hosts
if [ -d /etc/dnsmasq.d ]; then
  printf '%s\n' \
    'bind-interfaces' \
    'interface=docker0' \
    'except-interface=lo' \
    "address=/host.docker.internal/${GW}" \
    'no-resolv' \
    'server=1.1.1.1' \
    'server=8.8.8.8' \
    > /etc/dnsmasq.d/calf-host.conf
  systemctl try-reload-or-restart dnsmasq >/dev/null 2>&1 || true
fi
`
	if _, err := v.runGuestRoot(ctx, script); err != nil {
		guestLogger.Warn("host.docker.internal setup failed (non-fatal)", "error", err)
	}
}

// SetOwnerContext sets the parent context for guest background work (watchers, Buildx, proxy).
func (v *Guest) SetOwnerContext(ctx context.Context) {
	if ctx == nil {
		ctx = context.Background()
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	v.ownerCtx = ctx
}

// resetLifecycle cancels prior background work and returns a fresh lifecycle context.
func (v *Guest) resetLifecycle() context.Context {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.watcherCancel != nil {
		v.watcherCancel()
		v.watcherCancel = nil
	}
	parent := v.ownerCtx
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithCancel(parent)
	v.watcherCancel = cancel
	return ctx
}

// ensureBuildxAsync bootstraps buildx off the Start critical path.
func (v *Guest) ensureBuildxAsync(lifeCtx context.Context) {
	go func() {
		buildxCtx, cancel := context.WithTimeout(lifeCtx, constants.DefaultActionTimeout)
		defer cancel()
		if err := ensureBuildx(buildxCtx, v.guestCommandRunner); err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				return
			}
			guestLogger.Warn("buildx setup failed (non-fatal)", "error", err)
		}
	}()
}

// Stop tears down guest helpers unless vm_keep_alive is enabled (benchmarks force a full stop).
// Krunkit overrides Stop to terminate krunkit/gvproxy; this path is unused in product.
func (v *Guest) Stop(ctx context.Context) error {
	_ = ctx
	v.mu.Lock()
	if v.watcherCancel != nil {
		v.watcherCancel()
		v.watcherCancel = nil
	}
	v.mu.Unlock()
	v.localhostProxy.stopAll()
	v.started.Store(false)
	return nil
}

// Status reports whether the guest Docker API is reachable.
func (v *Guest) Status(ctx context.Context) (Status, error) {
	st := Status{Mode: Mode(constants.RuntimeModeVM), State: State(constants.RuntimeStateStopped), DockerSocket: v.dockerSocket, VMName: v.vmName}
	if v.dockerAPIReady(ctx) {
		st.State = State(constants.RuntimeStateRunning)
		if !v.started.Load() {
			v.started.Store(true)
			v.proxyResync.Store(true)
		}
	}
	st.PortConflicts = v.localhostProxy.conflictsSnapshot()
	return st, nil
}

func (v *Guest) waitForDockerAPI(ctx context.Context) error {
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
	return fmt.Errorf("docker API not ready for guest VM %q", v.vmName)
}

func (v *Guest) dockerAPIReady(ctx context.Context) bool {
	client := &http.Client{Timeout: 400 * time.Millisecond, Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", v.engineSocket)
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

// runLocal executes a command against the guest's Docker socket, retrying transient nerdctl
// failures. nerdctl is remapped to docker since the guest exposes a Docker-API socket.
func (v *Guest) runLocal(ctx context.Context, command string, args ...string) ([]byte, error) {
	if command == "nerdctl" {
		command = "docker"
	}
	env := os.Environ()
	env = dockerHostEnvFrom(env, v.engineSocket)
	if v.proxy != (ProxyConfig{}) {
		env = proxyEnvFrom(env, v.proxy)
	}
	return runCommandWithRetryEnv(ctx, constants.DefaultCommandRetries, constants.DefaultCommandRetryDelay, env, "", command, args...)
}

// runLocalWithStdin executes a command against the guest's Docker socket with stdin, retrying
// nerdctl on transient errors.
func (v *Guest) runLocalWithStdin(ctx context.Context, stdin, command string, args ...string) ([]byte, error) {
	if command == "nerdctl" {
		command = "docker"
	}
	env := dockerHostEnvFrom(os.Environ(), v.engineSocket)
	return runCommandWithRetryEnv(ctx, constants.DefaultCommandRetries, constants.DefaultCommandRetryDelay, env, stdin, command, args...)
}

// ListContainers returns all containers, or none when the runtime is stopped. Unlike Native, it
// also resyncs the localhost port-forwarding proxies from the container list.
func (v *Guest) ListContainers(ctx context.Context) ([]Container, error) {
	return emptyIfStopped(ctx, v.Status, func(ctx context.Context) ([]Container, error) {
		if !v.started.Load() {
			return []Container{}, nil
		}
		containers, err := v.cachedListContainers(ctx)
		if err == nil {
			force := v.proxyResync.Load()
			v.localhostProxy.sync(publishedTCPPorts(containers), force)
			if force {
				v.proxyResync.Store(false)
			}
		}
		return containers, err
	})
}

const containersListCacheTTL = 2 * time.Second

// cachedListContainers returns a short-lived shared list so UI polls, port watchers,
// and the stats sampler do not stampede docker ps over vsock.
func (v *Guest) cachedListContainers(ctx context.Context) ([]Container, error) {
	v.listMu.Lock()
	if v.listCache != nil && time.Since(v.listCacheAt) < containersListCacheTTL {
		out := append([]Container(nil), v.listCache...)
		v.listMu.Unlock()
		return out, nil
	}
	if v.listInflight != nil {
		wait := v.listInflight
		v.listMu.Unlock()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-wait:
		}
		v.listMu.Lock()
		out := append([]Container(nil), v.listInflightValue...)
		err := v.listInflightErr
		v.listMu.Unlock()
		if err != nil {
			return nil, err
		}
		return out, nil
	}
	wait := make(chan struct{})
	v.listInflight = wait
	v.listMu.Unlock()

	containers, err := listContainers(ctx, v.runLocal)

	v.listMu.Lock()
	v.listInflightErr = err
	v.listInflightValue = containers
	if err == nil {
		v.listCache = append([]Container(nil), containers...)
		v.listCacheAt = time.Now()
	}
	close(wait)
	v.listInflight = nil
	out := append([]Container(nil), containers...)
	v.listMu.Unlock()
	return out, err
}

// invalidateContainersCache drops the shared docker ps cache after mutations.
func (v *Guest) invalidateContainersCache() {
	v.listMu.Lock()
	v.listCache = nil
	v.listCacheAt = time.Time{}
	v.listMu.Unlock()
}

// ApplyProxy stores proxy settings and applies them inside the guest when running. Unlike
// Native, the guest always needs an in-VM apply since there is no host-level env inheritance.
func (v *Guest) ApplyProxy(ctx context.Context, proxy ProxyConfig) error {
	v.mu.Lock()
	v.proxy = proxy
	v.mu.Unlock()
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	return applyProxyInVM(ctx, v.guestCommandRunner, proxy)
}

// ListVolumeFiles lists directory entries inside a volume at path. Unlike Native, it runs
// through guestCommandRunner because volume mountpoints live inside the guest, not the host.
func (v *Guest) ListVolumeFiles(ctx context.Context, name, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return nil, err
	}
	if !isValidContainerPath(path) {
		return nil, fmt.Errorf("invalid path")
	}
	return listVolumeFiles(ctx, v.guestCommandRunner, name, path)
}

// RunBuild builds an image from contextPath and returns parsed build output, preferring buildx
// and falling back to a plain docker build when buildx is unavailable in the guest.
func (v *Guest) RunBuild(ctx context.Context, contextPath, tag, dockerfile, platform string) (BuildResult, error) {
	if err := requireRunning(ctx, v.Status); err != nil {
		return BuildResult{}, err
	}
	result, err := runBuildx(ctx, v.runLocal, contextPath, tag, dockerfile, platform)
	if err != nil && isBuildxMissingError(err) {
		guestLogger.Warn("buildx build failed; falling back to docker build", "error", err)
		return runBuild(ctx, v.runLocal, contextPath, tag, dockerfile, platform)
	}
	return result, err
}

// StartContainer starts a stopped container and drops the shared list cache.
func (v *Guest) StartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	_, err := v.runLocal(ctx, "nerdctl", "start", id)
	v.invalidateContainersCache()
	return err
}

// StopContainer stops a running container and drops the shared list cache.
func (v *Guest) StopContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	_, err := v.runLocal(ctx, "nerdctl", "stop", id)
	v.invalidateContainersCache()
	return err
}

// RemoveContainer force-removes a container and drops the shared list cache.
func (v *Guest) RemoveContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	_, err := v.runLocal(ctx, "nerdctl", "rm", "-f", id)
	v.invalidateContainersCache()
	return err
}

// StreamLogs tails recent history then follows new log lines for a container.
func (v *Guest) StreamLogs(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	history, err := v.runLocal(ctx, "nerdctl", "logs", "--tail", logTailLines, id)
	if err == nil {
		emitLogLines(output, history)
	}
	return v.streamLogsFollow(ctx, id, logsFollowSince(), output)
}

// StreamLogsFollow streams only new log lines from the current time onward.
func (v *Guest) StreamLogsFollow(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	return v.streamLogsFollow(ctx, id, logsFollowSince(), output)
}

// streamLogsFollow runs docker logs -f and pipes lines to output.
func (v *Guest) streamLogsFollow(ctx context.Context, id, since string, output func(string)) error {
	command := exec.CommandContext(ctx, "docker", "logs", "-f", "--since", since, id)
	command.Env = dockerHostEnvFrom(os.Environ(), v.engineSocket)
	return streamCommandLogs(ctx, command, output)
}

// AttachExec opens an interactive PTY session inside a container.
func (v *Guest) AttachExec(ctx context.Context, id string, stdin io.Reader, onOutput func([]byte), resizeCh <-chan ExecResize) error {
	if err := requireRunning(ctx, v.Status); err != nil {
		return err
	}
	command := exec.CommandContext(ctx, "docker", interactiveExecArgs(id)...)
	command.Env = dockerHostEnvFrom(os.Environ(), v.engineSocket)
	return attachContainerExec(ctx, command, stdin, onOutput, resizeCh)
}

// RegistryStatus reports whether the user is logged in to the default registry, reading Docker
// credentials from the host's ~/.docker/config.json regardless of whether the guest is running.
func (v *Guest) RegistryStatus(ctx context.Context) (RegistryStatus, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return RegistryStatus{Server: constants.DefaultRegistryServer}, nil
	}
	return registryStatus(ctx, v.runLocal, v.runLocalWithStdin, filepath.Join(home, ".docker", "config.json"))
}
