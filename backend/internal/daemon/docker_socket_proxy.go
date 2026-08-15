package daemon

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
)

const (
	// dockerProxyMaxConcurrent caps simultaneous dials into krunkit vsock.
	// Keep this modest: high fan-out floods virtio-vsock. Too low deadlocks
	// clients (e.g. docker CLI) that open more than one connection per command.
	dockerProxyMaxConcurrent   = 8
	dockerProxyReclaimInterval = 2 * time.Second
	dockerProxyDialProbe       = 2 * time.Second
	dockerProxyDialAfterWake   = 30 * time.Second
	dockerProxyMaxHTTPHeader   = 1 << 20

	// dockerProxyGuestMaxAPIVersion is the highest Docker Engine API the guest
	// dockerd accepts. Newer host CLIs (e.g. 29.7 → API 1.55) must be clamped
	// or buildx/compose fail with EOF / "client version too new".
	dockerProxyGuestMaxAPIVersion = "1.52"

	dockerProxyModeListen int32 = 0
)

// engineConnGater limits concurrent use of the guest Docker engine socket (vsock).
type engineConnGater interface {
	AcquireEngineConn(ctx context.Context) error
	ReleaseEngineConn()
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
	gater     engineConnGater
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
func newDockerSocketProxy(logger *slog.Logger, public, engine string, lifecycle context.Context, wake func(context.Context) error, gater engineConnGater) *dockerSocketProxy {
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

// handle wakes the engine when needed, then bidirectionally proxies to the engine socket.
func (p *dockerSocketProxy) handle(client net.Conn) {
	defer client.Close()

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

	proxyUnixConnection(client, server)
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
	var d net.Dialer
	var lastErr error
	deadline := time.Now().Add(timeout)
	if t, ok := ctx.Deadline(); ok && t.Before(deadline) {
		deadline = t
	}
	for time.Now().Before(deadline) {
		p.dialMu.Lock()
		conn, err := d.DialContext(ctx, "unix", p.engine)
		p.dialMu.Unlock()
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

// proxyUnixConnection forwards one Docker API connection.
//
// Plain HTTP: clamp API version, force Connection: close, forward one request
// body, then copy only engine→client. Keeping a client→engine copy open for
// keep-alive follow-ups wedges virtio-vsock when dockerd ignores close (buildx
// / compose fan-out then sees EOF on later calls).
//
// Hijacked streams (Upgrade: tcp) keep both directions open without CloseWrite
// on the engine side — vsock treats half-close as full teardown, which drops
// `docker run`/`exec` stdout.
func proxyUnixConnection(client, server net.Conn) {
	head, rest, upgrade, err := readDockerAPIRequestHead(client)
	if err != nil {
		return
	}
	if upgrade {
		proxyUnixUpgrade(client, server, head, rest)
		return
	}

	head = clampDockerAPIVersion(head, dockerProxyGuestMaxAPIVersion)
	head = forceHTTPConnectionClose(head)
	if _, err := server.Write(head); err != nil {
		return
	}
	if err := forwardDockerAPIRequestBody(server, client, rest, head); err != nil {
		return
	}
	_, _ = io.Copy(client, server)
	_ = client.Close()
	_ = server.Close()
}

// proxyUnixUpgrade bidirectionally proxies a Docker API hijacked stream.
func proxyUnixUpgrade(client, server net.Conn, head, rest []byte) {
	if _, err := server.Write(head); err != nil {
		return
	}
	clientReader := io.Reader(client)
	if len(rest) > 0 {
		clientReader = io.MultiReader(bytes.NewReader(rest), client)
	}

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(server, clientReader)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(client, server)
		done <- struct{}{}
	}()
	<-done
	<-done
	_ = client.Close()
	_ = server.Close()
}

// forwardDockerAPIRequestBody writes the remainder of a plain HTTP request body
// to the engine. Known Content-Length is copied exactly; chunked/unknown bodies
// fall back to draining rest then stopping (Docker API requests almost always
// set Content-Length).
func forwardDockerAPIRequestBody(server net.Conn, client net.Conn, rest []byte, head []byte) error {
	length, ok := httpRequestContentLength(head)
	if !ok {
		if len(rest) == 0 {
			return nil
		}
		_, err := server.Write(rest)
		return err
	}
	if length <= 0 {
		return nil
	}
	reader := io.Reader(client)
	if len(rest) > 0 {
		reader = io.MultiReader(bytes.NewReader(rest), client)
	}
	_, err := io.CopyN(server, reader, length)
	return err
}

// httpRequestContentLength parses Content-Length from an HTTP request head.
// ok is false when Transfer-Encoding is chunked or the length is missing/invalid
// while a body may still follow.
func httpRequestContentLength(head []byte) (int64, bool) {
	lower := bytes.ToLower(head)
	if bytes.Contains(lower, []byte("\r\ntransfer-encoding: chunked")) {
		return 0, false
	}
	for _, line := range bytes.Split(head, []byte("\r\n")) {
		lowerLine := bytes.ToLower(line)
		if !bytes.HasPrefix(lowerLine, []byte("content-length:")) {
			continue
		}
		value := strings.TrimSpace(string(line[len("content-length:"):]))
		n, err := strconv.ParseInt(value, 10, 64)
		if err != nil || n < 0 {
			return 0, false
		}
		return n, true
	}
	return 0, true
}

// clampDockerAPIVersion rewrites /v1.N/ in the request line when N is newer than
// maxVersion so host Docker CLIs newer than the guest engine still work.
func clampDockerAPIVersion(head []byte, maxVersion string) []byte {
	if len(head) == 0 || maxVersion == "" {
		return head
	}
	trimmed := bytes.TrimSuffix(head, []byte("\r\n\r\n"))
	lines := bytes.Split(trimmed, []byte("\r\n"))
	if len(lines) == 0 {
		return head
	}
	parts := bytes.SplitN(lines[0], []byte(" "), 3)
	if len(parts) < 2 {
		return head
	}
	path := parts[1]
	const prefix = "/v"
	idx := bytes.Index(path, []byte(prefix))
	if idx < 0 {
		return head
	}
	verStart := idx + len(prefix)
	verEnd := verStart
	for verEnd < len(path) {
		c := path[verEnd]
		if (c >= '0' && c <= '9') || c == '.' {
			verEnd++
			continue
		}
		break
	}
	if verEnd <= verStart {
		return head
	}
	clientVersion := string(path[verStart:verEnd])
	if !dockerAPIVersionNewer(clientVersion, maxVersion) {
		return head
	}
	newPath := make([]byte, 0, verStart+len(maxVersion)+(len(path)-verEnd))
	newPath = append(newPath, path[:verStart]...)
	newPath = append(newPath, maxVersion...)
	newPath = append(newPath, path[verEnd:]...)
	parts[1] = newPath
	lines[0] = bytes.Join(parts, []byte(" "))
	return append(bytes.Join(lines, []byte("\r\n")), []byte("\r\n\r\n")...)
}

// dockerAPIVersionNewer reports whether a is a higher Docker API version than b
// (dotted integers, e.g. 1.55 > 1.52).
func dockerAPIVersionNewer(a, b string) bool {
	aParts := strings.Split(a, ".")
	bParts := strings.Split(b, ".")
	n := len(aParts)
	if len(bParts) > n {
		n = len(bParts)
	}
	for i := 0; i < n; i++ {
		var av, bv int
		if i < len(aParts) {
			av, _ = strconv.Atoi(aParts[i])
		}
		if i < len(bParts) {
			bv, _ = strconv.Atoi(bParts[i])
		}
		if av != bv {
			return av > bv
		}
	}
	return false
}

// readDockerAPIRequestHead reads until the end of HTTP headers (or EOF).
func readDockerAPIRequestHead(r io.Reader) (head, rest []byte, upgrade bool, err error) {
	buf := make([]byte, 0, 4096)
	tmp := make([]byte, 2048)
	for {
		if len(buf) > dockerProxyMaxHTTPHeader {
			return nil, nil, false, fmt.Errorf("docker API headers exceed %d bytes", dockerProxyMaxHTTPHeader)
		}
		n, readErr := r.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
			if idx := bytes.Index(buf, []byte("\r\n\r\n")); idx >= 0 {
				head = buf[:idx+4]
				rest = buf[idx+4:]
				return head, rest, httpRequestHeadIsUpgrade(head), nil
			}
		}
		if readErr != nil {
			if len(buf) == 0 {
				return nil, nil, false, readErr
			}
			if readErr == io.EOF {
				return buf, nil, httpRequestHeadIsUpgrade(buf), nil
			}
			return nil, nil, false, readErr
		}
	}
}

// httpRequestHeadIsUpgrade reports a Docker API hijack (attach/exec/raw stream).
func httpRequestHeadIsUpgrade(head []byte) bool {
	return bytes.Contains(bytes.ToLower(head), []byte("\r\nupgrade:"))
}

// forceHTTPConnectionClose strips Connection headers and adds Connection: close.
func forceHTTPConnectionClose(head []byte) []byte {
	if len(head) == 0 {
		return head
	}
	trimmed := bytes.TrimSuffix(head, []byte("\r\n\r\n"))
	lines := bytes.Split(trimmed, []byte("\r\n"))
	out := make([][]byte, 0, len(lines)+1)
	for i, line := range lines {
		if i == 0 {
			out = append(out, line)
			continue
		}
		lower := bytes.ToLower(line)
		if bytes.HasPrefix(lower, []byte("connection:")) {
			continue
		}
		out = append(out, line)
	}
	out = append(out, []byte("Connection: close"))
	return append(bytes.Join(out, []byte("\r\n")), []byte("\r\n\r\n")...)
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
	inner := newDockerSocketProxy(slog.Default(), public, engine, lifecycle, wake, nil)
	return &DockerSocketProxy{inner: inner}
}

// ProxyUnixConnectionForTest exposes proxyUnixConnection for leak-regression tests.
func ProxyUnixConnectionForTest(client, server net.Conn) {
	proxyUnixConnection(client, server)
}

// ClampDockerAPIVersionForTest exposes clampDockerAPIVersion for unit tests.
func ClampDockerAPIVersionForTest(head []byte, maxVersion string) []byte {
	return clampDockerAPIVersion(head, maxVersion)
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
