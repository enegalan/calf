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
		close(p.doneCh)
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(p.public), 0o755); err != nil {
		close(p.doneCh)
		return fmt.Errorf("create docker socket dir: %w", err)
	}
	_ = os.Remove(p.public)
	listener, err := net.Listen("unix", p.public)
	if err != nil {
		close(p.doneCh)
		return fmt.Errorf("listen on docker socket %s: %w", p.public, err)
	}
	if err := os.Chmod(p.public, 0o666); err != nil {
		_ = listener.Close()
		_ = os.Remove(p.public)
		close(p.doneCh)
		return fmt.Errorf("chmod docker socket: %w", err)
	}
	p.mu.Lock()
	p.listener = listener
	p.mu.Unlock()
	go p.serve(listener)
	p.logger.Info("docker socket proxy listening", "public", p.public, "engine", p.engine)
	return nil
}

// Stop closes the public listener. When handOff is true and the engine socket
// still exists, replaces the public path with a symlink so vm_keep_alive CLI use
// keeps working after the daemon quits.
func (p *dockerSocketProxy) Stop(handOff bool) {
	if p == nil {
		return
	}
	select {
	case <-p.stopCh:
	default:
		close(p.stopCh)
	}
	p.mu.Lock()
	listener := p.listener
	p.listener = nil
	p.mu.Unlock()
	if listener != nil {
		_ = listener.Close()
	}
	<-p.doneCh
	_ = os.Remove(p.public)
	if handOff {
		if _, err := os.Stat(p.engine); err == nil {
			if err := os.Symlink(p.engine, p.public); err != nil {
				p.logger.Warn("docker socket hand-off symlink failed", "error", err)
			}
		}
	}
}

// serve accepts connections until the listener closes or stopCh fires.
func (p *dockerSocketProxy) serve(listener net.Listener) {
	defer close(p.doneCh)
	for {
		client, err := listener.Accept()
		if err != nil {
			select {
			case <-p.stopCh:
				return
			default:
				p.logger.Debug("docker socket accept ended", "error", err)
				return
			}
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

	if !p.engineDialable() {
		p.logger.Info("docker CLI connected while engine stopped; waking")
		if err := p.wake(ctx); err != nil {
			p.logger.Warn("docker socket wake failed", "error", err)
			return
		}
	}

	server, err := p.dialEngine(ctx)
	if err != nil {
		p.logger.Warn("docker socket dial engine failed", "error", err)
		return
	}
	defer server.Close()

	proxyUnixConnection(client, server)
}

// engineDialable reports whether the engine vsock socket accepts a connection right now.
func (p *dockerSocketProxy) engineDialable() bool {
	var d net.Dialer
	conn, err := d.Dial("unix", p.engine)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// dialEngine connects to the krunkit vsock socket with short retries.
func (p *dockerSocketProxy) dialEngine(ctx context.Context) (net.Conn, error) {
	var d net.Dialer
	var lastErr error
	deadline := time.Now().Add(30 * time.Second)
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

// Stop closes the proxy and optionally hands off via symlink.
func (p *DockerSocketProxy) Stop(handOff bool) {
	if p == nil || p.inner == nil {
		return
	}
	p.inner.Stop(handOff)
}
