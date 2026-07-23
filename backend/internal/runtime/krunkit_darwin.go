//go:build darwin

package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
)

// Krunkit is the macOS container engine: libkrun/krunkit + gvproxy networking.
// Guest disk/EFI/vsock live under ~/.config/calf/guest/<vm>/.
type Krunkit struct {
	*Guest
	gvproxyCmd *exec.Cmd

	forwardMu      sync.Mutex
	forwardedPorts map[int]struct{}
}

// NewKrunkit constructs the macOS Runtime (shared Guest disk helpers + krunkit/gvproxy).
func NewKrunkit(vmName, dockerSocket string, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort int, vmKeepAlive bool, proxy ProxyConfig) *Krunkit {
	return &Krunkit{
		Guest:          NewGuest(vmName, dockerSocket, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort, vmKeepAlive, proxy),
		forwardedPorts: make(map[int]struct{}),
	}
}

// krunkitPidPath returns the path of the krunkit process PID file.
func (k *Krunkit) krunkitPidPath() string {
	return filepath.Join(k.dataDir, "krunkit.pid")
}

// gvproxyPidPath returns the path of the gvproxy process PID file.
func (k *Krunkit) gvproxyPidPath() string {
	return filepath.Join(k.dataDir, "gvproxy.pid")
}

// gvproxySockPath returns the path of the gvproxy virtio-net unixgram socket.
func (k *Krunkit) gvproxySockPath() string {
	return filepath.Join(k.dataDir, "gvproxy.sock")
}

// gvproxyAPISockPath returns the path of the gvproxy HTTP services socket.
func (k *Krunkit) gvproxyAPISockPath() string {
	return filepath.Join(k.dataDir, "gvproxy-api.sock")
}

// resolveKrunkitBinary returns the krunkit executable.
// Order: CALF_KRUNKIT_BIN, next to this process / Resources/krunkit, ~/.config/calf/krunkit, PATH.
func resolveKrunkitBinary() string {
	if override := strings.TrimSpace(os.Getenv("CALF_KRUNKIT_BIN")); override != "" {
		if _, err := os.Stat(override); err == nil {
			return override
		}
	}
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		for _, candidate := range []string{
			filepath.Join(dir, "krunkit"),
			filepath.Join(dir, "..", "Resources", "krunkit", "bin", "krunkit"),
		} {
			if _, err := os.Stat(candidate); err == nil {
				return candidate
			}
		}
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidate := filepath.Join(home, ".config", "calf", "krunkit", "bin", "krunkit")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	if path, err := exec.LookPath("krunkit"); err == nil {
		return path
	}
	return ""
}

// resolveGvproxyBinary returns gvproxy: CALF_GVPROXY_BIN, next to this process, or PATH.
func resolveGvproxyBinary() string {
	if override := strings.TrimSpace(os.Getenv("CALF_GVPROXY_BIN")); override != "" {
		if _, err := os.Stat(override); err == nil {
			return override
		}
	}
	if exe, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(exe), "gvproxy")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	if path, err := exec.LookPath("gvproxy"); err == nil {
		return path
	}
	return ""
}

// libkrunDirFor returns the directory containing libkrun next to a krunkit binary, if present.
func libkrunDirFor(krunkitBin string) string {
	if override := strings.TrimSpace(os.Getenv("CALF_LIBKRUN_DIR")); override != "" {
		if _, err := os.Stat(filepath.Join(override, "libkrun.1.dylib")); err == nil {
			return override
		}
	}
	libDir := filepath.Clean(filepath.Join(filepath.Dir(krunkitBin), "..", "lib"))
	if _, err := os.Stat(filepath.Join(libDir, "libkrun.1.dylib")); err == nil {
		return libDir
	}
	return ""
}

// krunkitAlive reports whether the krunkit process from the PID file is still running.
func (k *Krunkit) krunkitAlive() bool {
	return pidfileAlive(k.krunkitPidPath())
}

// gvproxyAlive reports whether the gvproxy process from the PID file is still running.
func (k *Krunkit) gvproxyAlive() bool {
	return pidfileAlive(k.gvproxyPidPath())
}

// pidfileAlive reports whether the PID in path is still running.
func pidfileAlive(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid < 1 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}

// Start launches gvproxy + krunkit and waits for Docker /_ping on the vsock socket.
func (k *Krunkit) Start(ctx context.Context) error {
	krunkitBin := resolveKrunkitBinary()
	if krunkitBin == "" {
		return fmt.Errorf("krunkit not found: run make krunkit-stack, or install a release that bundles it (CALF_KRUNKIT_BIN overrides)")
	}
	gvproxyBin := resolveGvproxyBinary()
	if gvproxyBin == "" {
		return fmt.Errorf("gvproxy not found: brew install libkrun/krun/gvproxy, or use a release that bundles it (CALF_GVPROXY_BIN overrides)")
	}
	if _, err := exec.LookPath("docker"); err != nil {
		return fmt.Errorf("docker CLI not found: required for the krunkit runtime")
	}
	// Guest-disk download allows up to 45 minutes; do not inherit Start's short deadline.
	if err := k.ensureGuestDisk(context.WithoutCancel(ctx)); err != nil {
		return err
	}
	if err := os.MkdirAll(k.dataDir, 0o755); err != nil {
		return err
	}
	lifeCtx := k.resetLifecycle()
	if k.dockerAPIReady(ctx) && k.krunkitAlive() && k.gvproxyAlive() {
		k.ensureHostMountSymlink(ctx)
		k.ensureKrunkitDAXMount(ctx)
		k.ensureGuestNetwork(ctx)
		k.ensureBuildxAsync(lifeCtx)
		if os.Getenv("CALF_BENCHMARK") != "1" {
			go func() {
				setupCtx, cancel := context.WithTimeout(lifeCtx, constants.DefaultActionTimeout)
				defer cancel()
				k.ensureHostDockerInternal(setupCtx)
			}()
		}
		if k.proxy != (ProxyConfig{}) {
			proxy := k.proxy
			go func() {
				applyCtx, cancel := context.WithTimeout(lifeCtx, constants.DefaultActionTimeout)
				defer cancel()
				if err := k.ApplyProxy(applyCtx, proxy); err != nil {
					if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
						return
					}
					guestLogger.Warn("proxy application during krunkit start failed (non-fatal)", "error", err)
				}
			}()
		}
		k.started.Store(true)
		k.proxyResync.Store(true)
		go k.watchPortProxies(lifeCtx)
		return nil
	}
	_ = k.stopKrunkitStack()
	deadline := time.Now().Add(15 * time.Second)
	for (k.krunkitAlive() || k.gvproxyAlive()) && time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	_ = os.Remove(k.dockerSocket)
	_ = os.Remove(k.gvproxySockPath())
	if err := os.MkdirAll(filepath.Dir(k.dockerSocket), 0o755); err != nil {
		return err
	}

	if err := k.startGvproxy(gvproxyBin); err != nil {
		return err
	}

	// krunkit always requires the create flag on the EFI bootloader (unlike vfkit).
	bootloader := "efi,variable-store=" + k.efiPath() + ",create"
	home, err := os.UserHomeDir()
	if err != nil {
		home = os.TempDir()
	}
	mounts := filepath.Join(home, ".config", "calf", "mounts")
	_ = os.MkdirAll(mounts, 0o755)
	// mac= is required by krunkit; value is arbitrary (guest net uses Name=eth*, not MAC).
	netDevice := fmt.Sprintf(
		"virtio-net,type=unixgram,path=%s,mac=52:55:00:d1:55:01,offloading=on,vfkitMagic=on",
		k.gvproxySockPath(),
	)
	args := []string{
		"--cpus", strconv.Itoa(k.cpus),
		"--memory", strconv.Itoa(k.memoryGB * 1024),
		"--bootloader", bootloader,
		"--device", "virtio-blk,path=" + k.diskPath() + ",format=raw",
		"--device", netDevice,
		"--device", "virtio-fs,sharedDir=" + mounts + ",mountTag=calf-mounts,permissionSemantics=simplified",
		"--device", "virtio-vsock,port=2375,socketURL=" + k.dockerSocket + ",connect",
		"--pidfile", k.krunkitPidPath(),
		"--krun-log-level", "2",
	}
	cmd := exec.Command(krunkitBin, args...)
	if libDir := libkrunDirFor(krunkitBin); libDir != "" {
		cmd.Env = append(os.Environ(), "DYLD_LIBRARY_PATH="+libDir)
	}
	if logFile, err := os.OpenFile(filepath.Join(k.dataDir, "krunkit.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644); err == nil {
		cmd.Stdout = logFile
		cmd.Stderr = logFile
	}
	if err := cmd.Start(); err != nil {
		_ = k.stopKrunkitStack()
		return fmt.Errorf("start krunkit: %w", err)
	}
	k.mu.Lock()
	k.cmd = cmd
	k.mu.Unlock()
	go func() { _ = cmd.Wait(); k.started.Store(false) }()

	if err := k.waitForDockerAPI(ctx); err != nil {
		_ = k.stopKrunkitStack()
		return err
	}
	k.ensureHostMountSymlink(ctx)
	k.ensureKrunkitDAXMount(ctx)
	k.ensureGuestNetwork(ctx)
	k.ensureBuildxAsync(lifeCtx)
	if os.Getenv("CALF_BENCHMARK") != "1" {
		go func() {
			setupCtx, cancel := context.WithTimeout(lifeCtx, constants.DefaultActionTimeout)
			defer cancel()
			k.ensureHostDockerInternal(setupCtx)
		}()
	}
	if k.proxy != (ProxyConfig{}) {
		proxy := k.proxy
		go func() {
			applyCtx, cancel := context.WithTimeout(lifeCtx, constants.DefaultActionTimeout)
			defer cancel()
			if err := k.ApplyProxy(applyCtx, proxy); err != nil {
				if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
					return
				}
				guestLogger.Warn("proxy application during krunkit start failed (non-fatal)", "error", err)
			}
		}()
	}
	k.started.Store(true)
	k.proxyResync.Store(true)
	go k.watchPortProxies(lifeCtx)
	return nil
}

// ensureGuestNetwork brings up the virtio-net NIC via systemd-networkd.
// Existing guest disks ship a broken network unit (Name=enp* AND Name=eth* never matches)
// and a MAC-pinned cloud-init netplan, so eth0 stays DOWN without this.
func (k *Krunkit) ensureGuestNetwork(ctx context.Context) {
	script := `set -e
mkdir -p /etc/systemd/network
# One Name= line: whitespace-separated globs are OR'd. Two Name= lines are AND'd and never match.
# Static .2 matches gvproxy's default VM address (DHCP often hands out .3 and breaks forwards).
printf '%s\n' \
	'[Match]' \
	'Name=eth* enp*' \
	'' \
	'[Network]' \
	'Address=192.168.127.2/24' \
	'Gateway=192.168.127.1' \
	'DNS=192.168.127.1' \
	'DNS=1.1.1.1' \
	> /etc/systemd/network/20-calf-eth.network
rm -f /etc/systemd/network/20-calf-vz.network
# Drop MAC-pinned cloud-init netplan so networkd can own eth0.
if [ -f /etc/netplan/50-cloud-init.yaml ]; then
	mkdir -p /etc/netplan/disabled
	mv -f /etc/netplan/50-cloud-init.yaml /etc/netplan/disabled/50-cloud-init.yaml.bak 2>/dev/null || \
		rm -f /etc/netplan/50-cloud-init.yaml
fi
systemctl enable systemd-networkd >/dev/null 2>&1 || true
systemctl restart systemd-networkd
ip link set eth0 up 2>/dev/null || true
# Drop a stale DHCP lease address if present.
ip -4 addr flush dev eth0 2>/dev/null || true
networkctl reconfigure eth0 >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
	if ip -4 addr show eth0 | grep -q '192.168.127.2'; then
		if ip -4 route show default | grep -q .; then
			exit 0
		fi
	fi
	sleep 0.25
done
ip addr add 192.168.127.2/24 dev eth0 2>/dev/null || true
ip route replace default via 192.168.127.1 dev eth0 2>/dev/null || true
ip -4 addr show eth0 | grep -q '192.168.127.2'
ip -4 route show default | grep -q .`
	if _, err := k.runGuestRoot(ctx, script); err != nil {
		guestLogger.Warn("guest network setup failed (non-fatal)", "error", err)
	}
}

// startGvproxy launches gvproxy in vfkit listen mode for krunkit virtio-net.
func (k *Krunkit) startGvproxy(gvproxyBin string) error {
	_ = os.Remove(k.gvproxySockPath())
	_ = os.Remove(k.gvproxyPidPath())
	_ = os.Remove(k.gvproxyAPISockPath())
	args := []string{
		"-listen-vfkit", "unixgram://" + k.gvproxySockPath(),
		// Host HTTP API for dynamic port forwards (required: VZ NAT does this for vfkit).
		"-services", "unix://" + k.gvproxyAPISockPath(),
		"-pid-file", k.gvproxyPidPath(),
		"-mtu", "1500",
	}
	cmd := exec.Command(gvproxyBin, args...)
	if logFile, err := os.OpenFile(filepath.Join(k.dataDir, "gvproxy.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644); err == nil {
		cmd.Stdout = logFile
		cmd.Stderr = logFile
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start gvproxy: %w", err)
	}
	k.mu.Lock()
	k.gvproxyCmd = cmd
	k.mu.Unlock()
	go func() { _ = cmd.Wait() }()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(k.gvproxySockPath()); err == nil {
			if _, err := os.Stat(k.gvproxyAPISockPath()); err == nil {
				return nil
			}
		}
		// gvproxyAlive alone misses the window before the PID file exists; confirm via the process handle
		// (do not wait for Wait to set ProcessState — that lags behind a real exit).
		if !k.gvproxyAlive() {
			if cmd.Process == nil || syscall.Kill(cmd.Process.Pid, 0) != nil {
				return fmt.Errorf("gvproxy exited before creating %s", k.gvproxySockPath())
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	if _, err := os.Stat(k.gvproxySockPath()); err != nil {
		_ = k.stopGvproxy()
		return fmt.Errorf("gvproxy socket not ready at %s", k.gvproxySockPath())
	}
	// API sock is required for -p publish; fail closed so port-forward bugs surface early.
	if _, err := os.Stat(k.gvproxyAPISockPath()); err != nil {
		_ = k.stopGvproxy()
		return fmt.Errorf("gvproxy API socket not ready at %s", k.gvproxyAPISockPath())
	}
	return nil
}

// watchPortProxies forwards published container ports via gvproxy and keeps ::1→127.0.0.1 proxies.
func (k *Krunkit) watchPortProxies(ctx context.Context) {
	guestLogger.Info("krunkit port forward watcher started")
	syncOnce := func(force bool) {
		status, err := k.Status(ctx)
		if err != nil || status.State != State(constants.RuntimeStateRunning) || !k.started.Load() {
			return
		}
		containers, err := listContainers(ctx, k.runLocal)
		if err != nil {
			guestLogger.Warn("list containers for port forward failed", "error", err)
			k.proxyResync.Store(true)
			return
		}
		ports := publishedTCPPorts(containers)
		k.syncGvproxyForwards(ctx, ports)
		k.localhostProxy.sync(ports, force)
	}
	syncOnce(true)
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			force := k.proxyResync.Load()
			syncOnce(force)
			if force {
				k.proxyResync.Store(false)
			}
		}
	}
}

// syncGvproxyForwards exposes host ports to the guest eth0 address through gvproxy's services API.
func (k *Krunkit) syncGvproxyForwards(ctx context.Context, ports map[int]struct{}) {
	// Guest eth0 is pinned to gvproxy's default VM address in ensureGuestNetwork.
	const guestIP = "192.168.127.2"
	client := k.gvproxyHTTPClient()
	k.forwardMu.Lock()
	defer k.forwardMu.Unlock()
	for port := range k.forwardedPorts {
		if _, ok := ports[port]; ok {
			continue
		}
		if err := k.gvproxyUnexpose(ctx, client, port); err != nil {
			guestLogger.Warn("gvproxy port unexpose failed", "port", port, "error", err)
		}
		delete(k.forwardedPorts, port)
	}
	for port := range ports {
		if _, ok := k.forwardedPorts[port]; ok {
			continue
		}
		if err := k.gvproxyExpose(ctx, client, port, guestIP); err != nil {
			guestLogger.Warn("gvproxy port expose failed", "port", port, "error", err)
			continue
		}
		guestLogger.Info("gvproxy port exposed", "port", port, "guest", guestIP)
		k.forwardedPorts[port] = struct{}{}
	}
}

// gvproxyHTTPClient returns an HTTP client dialing the gvproxy -services unix socket.
func (k *Krunkit) gvproxyHTTPClient() *http.Client {
	sock := k.gvproxyAPISockPath()
	return &http.Client{
		Timeout: 3 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", sock)
			},
		},
	}
}

type gvproxyForward struct {
	Local  string `json:"local"`
	Remote string `json:"remote"`
}

// gvproxyExpose asks gvproxy to listen on host :port and forward to guestIP:port.
func (k *Krunkit) gvproxyExpose(ctx context.Context, client *http.Client, port int, guestIP string) error {
	body, err := json.Marshal(gvproxyForward{
		Local:  fmt.Sprintf(":%d", port),
		Remote: net.JoinHostPort(guestIP, strconv.Itoa(port)),
	})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://gvproxy/services/forwarder/expose", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("expose status %d", resp.StatusCode)
	}
	return nil
}

// gvproxyUnexpose removes a host port forward from gvproxy.
func (k *Krunkit) gvproxyUnexpose(ctx context.Context, client *http.Client, port int) error {
	body, err := json.Marshal(map[string]string{"local": fmt.Sprintf(":%d", port)})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://gvproxy/services/forwarder/unexpose", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("unexpose status %d", resp.StatusCode)
	}
	return nil
}

// ensureKrunkitDAXMount remounts calf-mounts with DAX virtiofs.
// Default: dax=inode. CALF_KRUN_DAX=0 forces plain virtiofs.
// CALF_KRUN_DAX_MODE=always maximizes bind-write (~4 GB/s) but weakens cold bind-read (~600 MiB/s).
func (k *Krunkit) ensureKrunkitDAXMount(ctx context.Context) {
	env := strings.TrimSpace(os.Getenv("CALF_KRUN_DAX"))
	if env == "0" {
		script := `umount /mnt/calf 2>/dev/null || true
mkdir -p /mnt/calf
mount -t virtiofs -o noatime calf-mounts /mnt/calf
dev=$(stat -c '%d' /mnt/calf 2>/dev/null || true)
if [ -n "$dev" ] && [ -w "/sys/class/bdi/0:${dev}/read_ahead_kb" ]; then
	echo 16384 > "/sys/class/bdi/0:${dev}/read_ahead_kb" 2>/dev/null || true
fi`
		_, _ = k.runGuestRoot(ctx, script)
		return
	}
	mode := strings.TrimSpace(os.Getenv("CALF_KRUN_DAX_MODE"))
	if mode == "" {
		mode = "inode"
	}
	script := `umount /mnt/calf 2>/dev/null || true
mkdir -p /mnt/calf
MODE='` + mode + `'
	case "$MODE" in
	inode)
		if ! mount -t virtiofs -o dax=inode,noatime calf-mounts /mnt/calf 2>/dev/null; then
			mount -t virtiofs -o noatime calf-mounts /mnt/calf || exit 1
		fi
		;;
	always|*)
		if ! mount -t virtiofs -o dax=always,noatime calf-mounts /mnt/calf 2>/dev/null; then
			mount -t virtiofs -o noatime calf-mounts /mnt/calf || exit 1
		fi
		;;
esac
# Grow virtiofs BDI readahead past the 128KiB FUSE default so sequential cold reads
# issue larger READ requests (matches libkrun max_write / max_readahead).
dev=$(stat -c '%d' /mnt/calf 2>/dev/null || true)
if [ -n "$dev" ] && [ -w "/sys/class/bdi/0:${dev}/read_ahead_kb" ]; then
	echo 16384 > "/sys/class/bdi/0:${dev}/read_ahead_kb" 2>/dev/null || true
fi`
	_, _ = k.runGuestRoot(ctx, script)
}

// Stop kills krunkit and gvproxy unless vm_keep_alive is enabled.
func (k *Krunkit) Stop(ctx context.Context) error {
	_ = ctx
	k.mu.Lock()
	if k.watcherCancel != nil {
		k.watcherCancel()
		k.watcherCancel = nil
	}
	k.mu.Unlock()
	k.localhostProxy.stopAll()
	k.started.Store(false)
	if k.vmKeepAlive && os.Getenv("CALF_BENCHMARK") != "1" {
		return nil
	}
	_ = k.stopKrunkitStack()
	_ = os.Remove(k.dockerSocket)
	return nil
}

// stopKrunkitStack terminates krunkit then gvproxy and removes their pid/socket files.
func (k *Krunkit) stopKrunkitStack() error {
	k.mu.Lock()
	cmd := k.cmd
	k.cmd = nil
	k.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Signal(syscall.SIGTERM)
		time.Sleep(200 * time.Millisecond)
		_ = cmd.Process.Kill()
	}
	killPidfile(k.krunkitPidPath())
	_ = os.Remove(k.krunkitPidPath())
	_ = k.stopGvproxy()
	return nil
}

// stopGvproxy terminates the gvproxy process and removes its socket.
func (k *Krunkit) stopGvproxy() error {
	k.mu.Lock()
	cmd := k.gvproxyCmd
	k.gvproxyCmd = nil
	k.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Signal(syscall.SIGTERM)
		time.Sleep(150 * time.Millisecond)
		_ = cmd.Process.Kill()
	}
	killPidfile(k.gvproxyPidPath())
	_ = os.Remove(k.gvproxyPidPath())
	_ = os.Remove(k.gvproxySockPath())
	_ = os.Remove(k.gvproxyAPISockPath())
	k.forwardMu.Lock()
	k.forwardedPorts = make(map[int]struct{})
	k.forwardMu.Unlock()
	return nil
}

// killPidfile sends SIGTERM then SIGKILL to the PID stored in path.
func killPidfile(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid < 1 {
		return
	}
	_ = syscall.Kill(pid, syscall.SIGTERM)
	time.Sleep(150 * time.Millisecond)
	_ = syscall.Kill(pid, syscall.SIGKILL)
}
