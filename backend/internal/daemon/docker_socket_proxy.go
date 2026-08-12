package daemon

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
)

// dockerSocketProxy listens on the public Docker CLI socket and forwards to the
// engine vsock socket. When the engine is stopped (Resource Saver), the first
// CLI connection wakes it via EnsureRuntimeRunning before forwarding.
type dockerSocketProxy struct {
	logger    *slog.Logger
	public    string
	engine    string
	wake      func(context.Context) error
	lifecycle context.Context

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
func newDockerSocketProxy(logger *slog.Logger, public, engine string, lifecycle context.Context, wake func(context.Context) error) *dockerSocketProxy {
	return &dockerSocketProxy{
		logger:    logger,
		public:    public,
		engine:    engine,
		wake:      wake,
		lifecycle: lifecycle,
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
	return p.listen()
}

// Rebind reclaims the public socket path if a symlink or other process replaced it.
func (p *dockerSocketProxy) Rebind() error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	stopped := p.stopped
	owns := !stopped && p.listener != nil && publicPathIsSocket(p.public)
	p.mu.Unlock()
	if stopped || owns {
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

// listen binds the public path and starts the accept loop.
func (p *dockerSocketProxy) listen() error {
	if err := os.MkdirAll(filepath.Dir(p.public), 0o755); err != nil {
		p.failDone()
		return fmt.Errorf("create docker socket dir: %w", err)
	}
	_ = os.Remove(p.public)
	listener, err := net.Listen("unix", p.public)
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

// handle wakes the engine when needed, then bidirectionally proxies to the engine socket.
func (p *dockerSocketProxy) handle(client net.Conn) {
	defer client.Close()

	parent := context.Background()
	if p.lifecycle != nil {
		parent = p.lifecycle
	}
	ctx, cancel := context.WithTimeout(parent, constants.GuestDiskFetchTimeout+3*time.Minute)
	defer cancel()

	server, err := p.dialEngine(ctx, 400*time.Millisecond)
	if err != nil {
		p.logger.Info("docker CLI connected while engine stopped; waking")
		if wakeErr := p.wake(ctx); wakeErr != nil {
			p.logger.Warn("docker socket wake failed", "error", wakeErr)
			return
		}
		server, err = p.dialEngine(ctx, 30*time.Second)
		if err != nil {
			p.logger.Warn("docker socket dial engine failed", "error", err)
			return
		}
	}
	defer server.Close()

	proxyUnixConnection(client, server)
}

// dialEngine connects to the krunkit vsock socket, retrying until timeout.
func (p *dockerSocketProxy) dialEngine(ctx context.Context, timeout time.Duration) (net.Conn, error) {
	var d net.Dialer
	var lastErr error
	deadline := time.Now().Add(timeout)
	if t, ok := ctx.Deadline(); ok && t.Before(deadline) {
		deadline = t
	}
	for time.Now().Before(deadline) {
		conn, err := d.DialContext(ctx, "unix", p.engine)
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

// proxyUnixConnection copies bytes both ways and half-closes on EOF.
func proxyUnixConnection(client, server net.Conn) {
	done := make(chan struct{}, 2)

	go func() {
		_, _ = io.Copy(server, client)
		closeWriteConn(server)
		done <- struct{}{}
	}()

	go func() {
		_, _ = io.Copy(client, server)
		closeWriteConn(client)
		done <- struct{}{}
	}()

	<-done
	<-done
}

// closeWriteConn half-closes the write side when the connection type supports it.
func closeWriteConn(conn net.Conn) {
	type closeWriter interface {
		CloseWrite() error
	}
	if cw, ok := conn.(closeWriter); ok {
		_ = cw.CloseWrite()
	}
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

// NewDockerSocketProxyForTest constructs a wake-on-connect proxy for unit tests.
func NewDockerSocketProxyForTest(public, engine string, lifecycle context.Context, wake func(context.Context) error) *DockerSocketProxy {
	inner := newDockerSocketProxy(slog.Default(), public, engine, lifecycle, wake)
	return &DockerSocketProxy{inner: inner}
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
