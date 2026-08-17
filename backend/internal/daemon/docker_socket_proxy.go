package daemon

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/runtime"
)

const (
	// dockerProxyMaxConcurrent caps simultaneous dials into krunkit vsock.
	// Keep this modest: virtio-vsock returns EOF under parallel Compose stops
	// (recreate). Too high floods the guest; queue extra CLI calls instead.
	dockerProxyMaxConcurrent   = 4
	dockerProxyReclaimInterval = 2 * time.Second
	dockerProxyDialProbe       = 2 * time.Second
	dockerProxyDialAfterWake   = 30 * time.Second

	dockerProxyModeListen int32 = 0
)

// EngineConnGater limits concurrent vsock use and serializes Dial into the guest engine.
type EngineConnGater interface {
	AcquireEngineConn(ctx context.Context) error
	ReleaseEngineConn()
	DialEngineSocket(ctx context.Context) (net.Conn, error)
}

// dockerSocketProxy listens on the public Docker CLI socket and forwards to the
// engine vsock socket. When the engine is stopped (Resource Saver), the first
// CLI connection wakes it via EnsureRuntimeRunning before forwarding.
//
// The public path stays a real listen socket (never a symlink to vsock). A gate
// limits concurrent dials into the guest so large `docker compose` image checks
// queue instead of failing with "Cannot connect to the Docker daemon".
type dockerSocketProxy struct {
	logger    *slog.Logger
	public    string
	engine    string
	wake      func(context.Context) error
	lifecycle context.Context
	gater     EngineConnGater
	gate      chan struct{}
	mode      atomic.Int32
	switchMu  sync.Mutex
	// dialMu serializes Dial into krunkit vsock. Parallel dials collapse the
	// virtio-vsock backend even when the concurrency gate still has free slots.
	dialMu sync.Mutex

	mu       sync.Mutex
	listener net.Listener
	stopCh   chan struct{}
	doneCh   chan struct{}
	stopped  bool
}

// engineDockerSocketer is implemented by runtimes that expose a separate vsock socket.
type engineDockerSocketer interface {
	EngineDockerSocket() string
}

// newDockerSocketProxy builds a wake-on-connect proxy when public and engine paths differ.
func newDockerSocketProxy(logger *slog.Logger, public, engine string, lifecycle context.Context, wake func(context.Context) error, gater EngineConnGater) *dockerSocketProxy {
	return &dockerSocketProxy{
		logger:    logger,
		public:    public,
		engine:    engine,
		wake:      wake,
		lifecycle: lifecycle,
		gater:     gater,
		gate:      make(chan struct{}, dockerProxyMaxConcurrent),
		stopCh:    make(chan struct{}),
		doneCh:    make(chan struct{}),
	}
}

// Start binds the public unix socket and accepts Docker CLI connections.
func (p *dockerSocketProxy) Start() error {
	if p == nil {
		return nil
	}
	if p.public == "" || p.engine == "" || p.public == p.engine {
		p.mu.Lock()
		p.stopped = true
		close(p.doneCh)
		p.mu.Unlock()
		return nil
	}
	if err := p.listen(); err != nil {
		return err
	}
	go p.watchPublicPath()
	return nil
}

// UseDirect keeps the public path in listen/proxy mode.
//
// Older releases symlinked docker.sock straight at the guest vsock while the
// engine was running. That flooded vsock under parallel Compose API calls and
// surfaced as "Cannot connect to the Docker daemon". The name remains for
// callers/tests; behavior is stay-proxied.
func (p *dockerSocketProxy) UseDirect() error {
	return p.UseProxy()
}

// UseProxy listens on the public path again (wake-on-connect mode).
func (p *dockerSocketProxy) UseProxy() error {
	if p == nil {
		return nil
	}
	p.switchMu.Lock()
	defer p.switchMu.Unlock()
	p.mu.Lock()
	stopped := p.stopped
	owns := p.listener != nil && publicPathIsSocket(p.public)
	p.mu.Unlock()
	if stopped {
		return nil
	}
	if p.mode.Load() == dockerProxyModeListen && owns {
		return nil
	}
	p.shutdownListener()
	if err := p.listen(); err != nil {
		return err
	}
	p.mode.Store(dockerProxyModeListen)
	return nil
}

// Rebind restores a working public listen socket after ForceStop, a raced hand-off,
// or a leftover symlink from older calf releases.
func (p *dockerSocketProxy) Rebind() error {
	if p == nil {
		return nil
	}
	p.switchMu.Lock()
	defer p.switchMu.Unlock()
	p.mu.Lock()
	stopped := p.stopped
	p.mu.Unlock()
	if stopped {
		return nil
	}

	info, err := os.Lstat(p.public)
	if err == nil && info.Mode()&os.ModeSymlink != 0 {
		p.logger.Info("docker socket proxy reclaiming symlink public path", "public", p.public)
		p.shutdownListener()
		return p.listen()
	}

	p.mu.Lock()
	owns := p.listener != nil && publicPathIsSocket(p.public)
	p.mu.Unlock()
	if owns {
		return nil
	}
	p.logger.Info("docker socket proxy reclaiming public path", "public", p.public)
	p.shutdownListener()
	return p.listen()
}

// Stop closes the public listener and removes the public socket path.
func (p *dockerSocketProxy) Stop() {
	if p == nil {
		return
	}
	p.switchMu.Lock()
	defer p.switchMu.Unlock()
	p.mu.Lock()
	if p.stopped {
		p.mu.Unlock()
		return
	}
	p.stopped = true
	p.mu.Unlock()
	p.shutdownListener()
	_ = os.Remove(p.public)
}

// watchPublicPath periodically repairs docker.sock after upgrade races or crashes.
func (p *dockerSocketProxy) watchPublicPath() {
	if p.lifecycle == nil {
		return
	}
	ticker := time.NewTicker(dockerProxyReclaimInterval)
	defer ticker.Stop()
	for {
		select {
		case <-p.lifecycle.Done():
			return
		case <-ticker.C:
			if err := p.Rebind(); err != nil {
				p.logger.Debug("docker socket proxy reclaim tick failed", "error", err)
			}
		}
	}
}

// listen binds the public path and starts the accept loop.
func (p *dockerSocketProxy) listen() error {
	if err := os.MkdirAll(filepath.Dir(p.public), 0o755); err != nil {
		p.failDone()
		return fmt.Errorf("create docker socket dir: %w", err)
	}
	_ = os.Remove(p.public)
	var lc net.ListenConfig
	listener, err := lc.Listen(context.Background(), "unix", p.public)
	if err != nil {
		p.failDone()
		return fmt.Errorf("listen on docker socket %s: %w", p.public, err)
	}
	if err := os.Chmod(p.public, 0o666); err != nil {
		_ = listener.Close()
		_ = os.Remove(p.public)
		p.failDone()
		return fmt.Errorf("chmod docker socket: %w", err)
	}

	p.mu.Lock()
	p.listener = listener
	p.stopCh = make(chan struct{})
	doneCh := make(chan struct{})
	p.doneCh = doneCh
	p.stopped = false
	p.mu.Unlock()
	p.mode.Store(dockerProxyModeListen)

	go p.serve(listener, doneCh)
	p.logger.Info("docker socket proxy listening", "public", p.public, "engine", p.engine)
	return nil
}

// shutdownListener closes the current accept loop and waits for it to exit.
func (p *dockerSocketProxy) shutdownListener() {
	p.mu.Lock()
	listener := p.listener
	stopCh := p.stopCh
	doneCh := p.doneCh
	p.listener = nil
	p.mu.Unlock()

	if stopCh != nil {
		select {
		case <-stopCh:
		default:
			close(stopCh)
		}
	}
	if listener != nil {
		_ = listener.Close()
	}
	if doneCh != nil {
		<-doneCh
	}
}

// failDone closes doneCh when Start fails before serve runs.
func (p *dockerSocketProxy) failDone() {
	p.mu.Lock()
	defer p.mu.Unlock()
	select {
	case <-p.doneCh:
	default:
		close(p.doneCh)
	}
}

// publicPathIsSocket reports whether path exists as a non-symlink unix socket.
func publicPathIsSocket(path string) bool {
	info, err := os.Lstat(path)
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeSymlink == 0 && info.Mode()&os.ModeSocket != 0
}

// serve accepts connections until the listener closes.
func (p *dockerSocketProxy) serve(listener net.Listener, doneCh chan struct{}) {
	defer close(doneCh)
	for {
		client, err := listener.Accept()
		if err != nil {
			return
		}
		go p.handle(client)
	}
}

// handle reads the CLI request first, then dials vsock. Dialing on accept
// (before any HTTP) spends a guest connection on idle Compose/buildx sockets
// and the virtio-vsock backend starts returning EOF on later _ping calls.
func (p *dockerSocketProxy) handle(client net.Conn) {
	defer client.Close()

	_ = client.SetReadDeadline(time.Now().Add(runtime.DockerAPIHeaderReadTimeout))
	head, rest, upgrade, err := runtime.ReadDockerAPIRequestHead(client)
	if err != nil {
		return
	}
	_ = client.SetReadDeadline(time.Time{})

	parent := context.Background()
	if p.lifecycle != nil {
		parent = p.lifecycle
	}
	if err := p.acquireConn(parent); err != nil {
		return
	}
	defer p.releaseConn()

	ctx, cancel := context.WithTimeout(parent, constants.GuestDiskFetchTimeout+3*time.Minute)
	defer cancel()

	server, err := p.dialEngine(ctx, dockerProxyDialProbe)
	if err != nil {
		p.logger.Info("docker CLI connected while engine stopped; waking")
		if wakeErr := p.wake(ctx); wakeErr != nil {
			p.logger.Warn("docker socket wake failed", "error", wakeErr)
			return
		}
		server, err = p.dialEngine(ctx, dockerProxyDialAfterWake)
		if err != nil {
			p.logger.Warn("docker socket dial engine failed", "error", err)
			return
		}
	}
	defer server.Close()

	runtime.ProxyDockerAPIWithHead(client, server, head, rest, upgrade)
}

// acquireConn takes a shared vsock slot (or the local gate when no gater is set).
func (p *dockerSocketProxy) acquireConn(ctx context.Context) error {
	if p.gater != nil {
		return p.gater.AcquireEngineConn(ctx)
	}
	select {
	case p.gate <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// releaseConn frees the slot taken by acquireConn.
func (p *dockerSocketProxy) releaseConn() {
	if p.gater != nil {
		p.gater.ReleaseEngineConn()
		return
	}
	select {
	case <-p.gate:
	default:
	}
}

// dialEngine connects to the krunkit vsock socket, retrying until timeout.
func (p *dockerSocketProxy) dialEngine(ctx context.Context, timeout time.Duration) (net.Conn, error) {
	var lastErr error
	deadline := time.Now().Add(timeout)
	if t, ok := ctx.Deadline(); ok && t.Before(deadline) {
		deadline = t
	}
	for time.Now().Before(deadline) {
		conn, err := p.dialEngineOnce(ctx)
		if err == nil {
			return conn, nil
		}
		lastErr = err
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("engine socket not ready at %s", p.engine)
	}
	return nil, lastErr
}

// dialEngineOnce opens one engine connection, using the guest dialer when set.
func (p *dockerSocketProxy) dialEngineOnce(ctx context.Context) (net.Conn, error) {
	if p.gater != nil {
		return p.gater.DialEngineSocket(ctx)
	}
	p.dialMu.Lock()
	defer p.dialMu.Unlock()
	var d net.Dialer
	return d.DialContext(ctx, "unix", p.engine)
}

// resolveEngineDockerSocket returns the vsock path when the runtime exposes one.
func resolveEngineDockerSocket(rt interface{ DockerSocket() string }) string {
	if provider, ok := rt.(engineDockerSocketer); ok {
		if engine := provider.EngineDockerSocket(); engine != "" {
			return engine
		}
	}
	return rt.DockerSocket()
}

// NewDockerSocketProxyWithGaterForTest constructs a proxy that dials the engine through gater.
func NewDockerSocketProxyWithGaterForTest(public, engine string, lifecycle context.Context, wake func(context.Context) error, gater EngineConnGater) *DockerSocketProxy {
	inner := newDockerSocketProxy(slog.Default(), public, engine, lifecycle, wake, gater)
	return &DockerSocketProxy{inner: inner}
}

// NewDockerSocketProxyForTest constructs a wake-on-connect proxy for unit tests.
func NewDockerSocketProxyForTest(public, engine string, lifecycle context.Context, wake func(context.Context) error) *DockerSocketProxy {
	inner := newDockerSocketProxy(slog.Default(), public, engine, lifecycle, wake, nil)
	return &DockerSocketProxy{inner: inner}
}

// ProxyUnixConnectionForTest exposes ProxyDockerAPI for leak-regression tests.
func ProxyUnixConnectionForTest(client, server net.Conn) {
	runtime.ProxyDockerAPI(client, server)
}

// ClampDockerAPIVersionForTest exposes ClampDockerAPIVersion for unit tests.
func ClampDockerAPIVersionForTest(head []byte, maxVersion string) []byte {
	return runtime.ClampDockerAPIVersion(head, maxVersion)
}

// DockerSocketProxy is the exported test/handle surface for the public Docker CLI socket proxy.
type DockerSocketProxy struct {
	inner *dockerSocketProxy
}

// Start binds the public unix socket.
func (p *DockerSocketProxy) Start() error {
	if p == nil || p.inner == nil {
		return nil
	}
	return p.inner.Start()
}

// Stop closes the proxy.
func (p *DockerSocketProxy) Stop() {
	if p == nil || p.inner == nil {
		return
	}
	p.inner.Stop()
}

// Rebind reclaims the public socket path for tests.
func (p *DockerSocketProxy) Rebind() error {
	if p == nil || p.inner == nil {
		return nil
	}
	return p.inner.Rebind()
}

// UseDirect keeps listen/proxy mode (no longer symlinks to the engine socket).
func (p *DockerSocketProxy) UseDirect() error {
	if p == nil || p.inner == nil {
		return nil
	}
	return p.inner.UseDirect()
}

// UseProxy switches back to listen mode for tests.
func (p *DockerSocketProxy) UseProxy() error {
	if p == nil || p.inner == nil {
		return nil
	}
	return p.inner.UseProxy()
}
