package daemon_test

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/daemon"
)

// TestDockerSocketProxyWakesAndForwards verifies a CLI connection wakes a stopped
// engine socket and then proxies HTTP to it.
func TestDockerSocketProxyWakesAndForwards(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "calf-dsp-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	public := filepath.Join(dir, "docker.sock")
	engine := filepath.Join(dir, "engine.sock")

	var wakeCount atomic.Int32
	var engineLn net.Listener
	life, cancel := context.WithCancel(context.Background())
	defer cancel()
	proxy := daemon.NewDockerSocketProxyForTest(
		public,
		engine,
		life,
		func(ctx context.Context) error {
			wakeCount.Add(1)
			_ = os.Remove(engine)
			ln, err := net.Listen("unix", engine)
			if err != nil {
				return fmt.Errorf("engine listen: %w", err)
			}
			engineLn = ln
			mux := http.NewServeMux()
			mux.HandleFunc("/_ping", func(w http.ResponseWriter, _ *http.Request) {
				_, _ = w.Write([]byte("OK"))
			})
			go func() { _ = http.Serve(ln, mux) }()
			return nil
		},
	)
	if err := proxy.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer func() {
		proxy.Stop()
		if engineLn != nil {
			_ = engineLn.Close()
		}
	}()

	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", public)
			},
			DisableKeepAlives: true,
		},
	}
	req, err := http.NewRequest(http.MethodGet, "http://localhost/_ping", nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d body %q", resp.StatusCode, body)
	}
	if string(body) != "OK" {
		t.Fatalf("body %q", body)
	}
	if wakeCount.Load() != 1 {
		t.Fatalf("wake count %d, want 1", wakeCount.Load())
	}
}

// TestDockerSocketProxyUseDirectKeepsListenSocket verifies UseDirect no longer
// symlinks to vsock (that flooded the guest under parallel Compose calls).
func TestDockerSocketProxyUseDirectKeepsListenSocket(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "calf-dsp-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	public := filepath.Join(dir, "docker.sock")
	engine := filepath.Join(dir, "engine.sock")
	ln, err := net.Listen("unix", engine)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	life, cancel := context.WithCancel(context.Background())
	defer cancel()
	proxy := daemon.NewDockerSocketProxyForTest(public, engine, life, func(context.Context) error {
		return nil
	})
	if err := proxy.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer proxy.Stop()

	if err := proxy.UseDirect(); err != nil {
		t.Fatalf("UseDirect: %v", err)
	}
	info, err := os.Lstat(public)
	if err != nil {
		t.Fatalf("Lstat after UseDirect: %v", err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("UseDirect must not symlink public path to engine")
	}
	if info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("public path is not a socket")
	}
}

// TestDockerSocketProxyRebindRepairsBrokenSymlink restores listen mode after a
// leftover symlink (e.g. from an older calf release).
func TestDockerSocketProxyRebindRepairsBrokenSymlink(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "calf-dsp-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	public := filepath.Join(dir, "docker.sock")
	engine := filepath.Join(dir, "engine.sock")
	if err := os.WriteFile(engine, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	life, cancel := context.WithCancel(context.Background())
	defer cancel()
	proxy := daemon.NewDockerSocketProxyForTest(public, engine, life, func(context.Context) error {
		return nil
	})
	if err := proxy.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer proxy.Stop()

	proxy.Stop()
	_ = os.Remove(public)
	if err := os.Symlink(engine, public); err != nil {
		t.Fatalf("Symlink: %v", err)
	}
	_ = os.Remove(engine)

	life2, cancel2 := context.WithCancel(context.Background())
	defer cancel2()
	proxy2 := daemon.NewDockerSocketProxyForTest(public, engine, life2, func(context.Context) error {
		return nil
	})
	if err := proxy2.Start(); err != nil {
		t.Fatalf("Start after symlink: %v", err)
	}
	defer proxy2.Stop()
	if err := proxy2.Rebind(); err != nil {
		t.Fatalf("Rebind: %v", err)
	}
	info, err := os.Lstat(public)
	if err != nil {
		t.Fatalf("Lstat after rebind: %v", err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("public path still a symlink after repair")
	}
}

// TestDockerSocketProxyQueuesUnderLoad verifies parallel CLI calls queue and
// complete when many clients hit the public proxy at once.
func TestDockerSocketProxyQueuesUnderLoad(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "calf-dsp-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	public := filepath.Join(dir, "docker.sock")
	engine := filepath.Join(dir, "engine.sock")

	ln, err := net.Listen("unix", engine)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 4096)
				_, _ = c.Read(buf)
				_, _ = c.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))
			}(conn)
		}
	}()

	life, cancel := context.WithCancel(context.Background())
	defer cancel()
	proxy := daemon.NewDockerSocketProxyForTest(public, engine, life, func(context.Context) error {
		return nil
	})
	if err := proxy.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer proxy.Stop()

	const parallel = 24
	var wg sync.WaitGroup
	var okCount atomic.Int32
	client := &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", public)
			},
			DisableKeepAlives: true,
			MaxIdleConns:      parallel,
		},
	}
	for i := 0; i < parallel; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, err := client.Get("http://localhost/_ping")
			if err != nil {
				return
			}
			defer resp.Body.Close()
			body, _ := io.ReadAll(resp.Body)
			if resp.StatusCode == http.StatusOK && string(body) == "OK" {
				okCount.Add(1)
			}
		}()
	}
	wg.Wait()
	if okCount.Load() != parallel {
		t.Fatalf("ok=%d want %d", okCount.Load(), parallel)
	}
}

// TestProxyUnixConnectionKeepsEngineSideOpenAfterClientWriteEOF verifies that
// when the CLI half-closes after an attach upgrade, the proxy still forwards
// engine→client bytes (vsock cannot tolerate CloseWrite on the engine socket).
func TestProxyUnixConnectionKeepsEngineSideOpenAfterClientWriteEOF(t *testing.T) {
	clientLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer clientLn.Close()
	serverLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer serverLn.Close()

	clientAccepted := make(chan net.Conn, 1)
	serverAccepted := make(chan net.Conn, 1)
	go func() {
		c, err := clientLn.Accept()
		if err == nil {
			clientAccepted <- c
		}
	}()
	go func() {
		c, err := serverLn.Accept()
		if err == nil {
			serverAccepted <- c
		}
	}()

	clientDial, err := net.Dial("tcp", clientLn.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer clientDial.Close()
	serverDial, err := net.Dial("tcp", serverLn.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer serverDial.Close()

	clientProxy := <-clientAccepted
	serverProxy := <-serverAccepted

	done := make(chan struct{})
	go func() {
		daemon.ProxyUnixConnectionForTest(clientProxy, serverProxy)
		close(done)
	}()

	attachReq := "" +
		"POST /v1.51/containers/x/attach?stdout=1&stream=1 HTTP/1.1\r\n" +
		"Host: localhost\r\n" +
		"Connection: Upgrade\r\n" +
		"Upgrade: tcp\r\n" +
		"\r\n"
	if _, err := clientDial.Write([]byte(attachReq)); err != nil {
		t.Fatalf("client write: %v", err)
	}
	reqBuf := make([]byte, len(attachReq)+64)
	_ = serverDial.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, err := io.ReadFull(serverDial, reqBuf[:len(attachReq)])
	if err != nil {
		t.Fatalf("server read request: %v", err)
	}
	if !bytes.Contains(bytes.ToLower(reqBuf[:n]), []byte("upgrade: tcp")) {
		t.Fatalf("engine did not receive upgrade request: %q", reqBuf[:n])
	}

	tcpClient, ok := clientDial.(*net.TCPConn)
	if !ok {
		t.Fatal("expected TCP conn")
	}
	if err := tcpClient.CloseWrite(); err != nil {
		t.Fatalf("CloseWrite: %v", err)
	}

	// Engine still responds after the client write half-close.
	time.Sleep(50 * time.Millisecond)
	if _, err := serverDial.Write([]byte("STDOUT")); err != nil {
		t.Fatalf("server write after client CloseWrite: %v", err)
	}
	_ = serverDial.Close()

	buf := make([]byte, 16)
	_ = clientDial.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, err = clientDial.Read(buf)
	if err != nil {
		t.Fatalf("client read: %v", err)
	}
	if string(buf[:n]) != "STDOUT" {
		t.Fatalf("got %q, want STDOUT", buf[:n])
	}

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("proxy did not finish after engine closed")
	}
}

// TestProxyUnixConnectionForcesConnectionCloseOnPlainHTTP ensures keep-alive
// plain requests become Connection: close so the engine frees the vsock slot.
func TestProxyUnixConnectionForcesConnectionCloseOnPlainHTTP(t *testing.T) {
	clientA, clientB := net.Pipe()
	serverA, serverB := net.Pipe()

	done := make(chan struct{})
	go func() {
		daemon.ProxyUnixConnectionForTest(clientA, serverA)
		close(done)
	}()

	req := "GET /_ping HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
	if _, err := clientB.Write([]byte(req)); err != nil {
		t.Fatalf("client write: %v", err)
	}
	go func() { _, _ = io.Copy(io.Discard, clientB) }()

	buf := make([]byte, 512)
	_ = serverB.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, err := serverB.Read(buf)
	if err != nil {
		t.Fatalf("server read: %v", err)
	}
	got := string(buf[:n])
	if !bytes.Contains(bytes.ToLower(buf[:n]), []byte("connection: close")) {
		t.Fatalf("missing Connection: close in %q", got)
	}
	if bytes.Contains(bytes.ToLower(buf[:n]), []byte("connection: keep-alive")) {
		t.Fatalf("keep-alive still present in %q", got)
	}

	if _, err := serverB.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")); err != nil {
		t.Fatalf("server write: %v", err)
	}
	_ = serverB.Close()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("proxy did not finish after plain HTTP response")
	}
}

// TestClampDockerAPIVersionDowngradesNewerClientPaths rewrites /v1.55/ to the
// guest max so newer host Docker CLIs work against the guest engine.
func TestClampDockerAPIVersionDowngradesNewerClientPaths(t *testing.T) {
	req := "GET /v1.55/containers/buildx_buildkit_default/json HTTP/1.1\r\nHost: localhost\r\n\r\n"
	got := daemon.ClampDockerAPIVersionForTest([]byte(req), constants.GuestDockerAPIVersion)
	if !bytes.Contains(got, []byte("GET /v"+constants.GuestDockerAPIVersion+"/containers/buildx_buildkit_default/json HTTP/1.1")) {
		t.Fatalf("clamp failed: %q", got)
	}
	if bytes.Contains(got, []byte("/v1.55/")) {
		t.Fatalf("old version still present: %q", got)
	}

	same := "GET /v" + constants.GuestDockerAPIVersion + "/version HTTP/1.1\r\nHost: localhost\r\n\r\n"
	out := daemon.ClampDockerAPIVersionForTest([]byte(same), constants.GuestDockerAPIVersion)
	if !bytes.Equal(out, []byte(same)) {
		t.Fatalf("same version mutated: %q", out)
	}

	older := "GET /v1.44/_ping HTTP/1.1\r\nHost: localhost\r\n\r\n"
	out = daemon.ClampDockerAPIVersionForTest([]byte(older), constants.GuestDockerAPIVersion)
	if !bytes.Equal(out, []byte(older)) {
		t.Fatalf("older version mutated: %q", out)
	}
}

// TestProxyUnixConnectionClampsAPIVersionAndCloses verifies plain HTTP requests
// are rewritten to the guest max API and finish without a keep-alive hang.
func TestProxyUnixConnectionClampsAPIVersionAndCloses(t *testing.T) {
	clientA, clientB := net.Pipe()
	serverA, serverB := net.Pipe()

	done := make(chan struct{})
	go func() {
		daemon.ProxyUnixConnectionForTest(clientA, serverA)
		close(done)
	}()

	req := "GET /v1.55/containers/json HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
	if _, err := clientB.Write([]byte(req)); err != nil {
		t.Fatalf("client write: %v", err)
	}
	go func() { _, _ = io.Copy(io.Discard, clientB) }()

	buf := make([]byte, 512)
	_ = serverB.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, err := serverB.Read(buf)
	if err != nil {
		t.Fatalf("server read: %v", err)
	}
	got := buf[:n]
	if !bytes.Contains(got, []byte("GET /v"+constants.GuestDockerAPIVersion+"/containers/json HTTP/1.1")) {
		t.Fatalf("missing clamped path in %q", got)
	}
	if !bytes.Contains(bytes.ToLower(got), []byte("connection: close")) {
		t.Fatalf("missing Connection: close in %q", got)
	}

	if _, err := serverB.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]")); err != nil {
		t.Fatalf("server write: %v", err)
	}
	_ = serverB.Close()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("proxy did not finish after clamped HTTP response")
	}
}

// TestProxyUnixConnectionForwardsRequestBody copies Content-Length body bytes
// before reading the engine response (compose build POST payloads).
func TestProxyUnixConnectionForwardsRequestBody(t *testing.T) {
	clientA, clientB := net.Pipe()
	serverA, serverB := net.Pipe()

	done := make(chan struct{})
	go func() {
		daemon.ProxyUnixConnectionForTest(clientA, serverA)
		close(done)
	}()

	body := []byte(`{"Image":"alpine"}`)
	req := fmt.Sprintf(
		"POST /v1.55/containers/create HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n",
		len(body),
	)
	if _, err := clientB.Write(append([]byte(req), body...)); err != nil {
		t.Fatalf("client write: %v", err)
	}
	go func() { _, _ = io.Copy(io.Discard, clientB) }()

	buf := make([]byte, 1024)
	_ = serverB.SetReadDeadline(time.Now().Add(2 * time.Second))
	var got []byte
	for !bytes.Contains(got, body) {
		n, err := serverB.Read(buf)
		if n > 0 {
			got = append(got, buf[:n]...)
		}
		if err != nil {
			t.Fatalf("server read: %v (got %q)", err, got)
		}
	}
	if !bytes.Contains(got, []byte("POST /v"+constants.GuestDockerAPIVersion+"/containers/create HTTP/1.1")) {
		t.Fatalf("missing clamped path in %q", got)
	}

	if _, err := serverB.Write([]byte("HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\n{}")); err != nil {
		t.Fatalf("server write: %v", err)
	}
	_ = serverB.Close()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("proxy did not finish after body forward")
	}
}

// serialTestGater serializes engine dials for proxy tests.
type serialTestGater struct {
	engine string
	mu     sync.Mutex
	dials  atomic.Int32
}

func (g *serialTestGater) AcquireEngineConn(ctx context.Context) error {
	return ctx.Err()
}

func (g *serialTestGater) ReleaseEngineConn() {}

func (g *serialTestGater) DialEngineSocket(ctx context.Context) (net.Conn, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.dials.Add(1)
	var d net.Dialer
	return d.DialContext(ctx, "unix", g.engine)
}

func TestDockerSocketProxyDialsThroughGater(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "calf-dsp-gater-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	public := filepath.Join(dir, "docker.sock")
	engine := filepath.Join(dir, "engine.sock")

	ln, err := net.Listen("unix", engine)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 4096)
				_, _ = c.Read(buf)
				_, _ = c.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))
			}(conn)
		}
	}()

	life, cancel := context.WithCancel(context.Background())
	defer cancel()
	gater := &serialTestGater{engine: engine}
	proxy := daemon.NewDockerSocketProxyWithGaterForTest(public, engine, life, func(context.Context) error {
		return nil
	}, gater)
	if err := proxy.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer proxy.Stop()

	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", public)
			},
			DisableKeepAlives: true,
		},
	}
	resp, err := client.Get("http://localhost/_ping")
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || string(body) != "OK" {
		t.Fatalf("status %d body %q", resp.StatusCode, body)
	}
	if gater.dials.Load() < 1 {
		t.Fatal("gater DialEngineSocket was not used")
	}
}

func TestDockerSocketProxyDoesNotDialUntilRequest(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "calf-dsp-idle-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	public := filepath.Join(dir, "docker.sock")
	engine := filepath.Join(dir, "engine.sock")

	ln, err := net.Listen("unix", engine)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	var accepts atomic.Int32
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			accepts.Add(1)
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 4096)
				_, _ = c.Read(buf)
				_, _ = c.Write([]byte("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))
			}(conn)
		}
	}()

	life, cancel := context.WithCancel(context.Background())
	defer cancel()
	proxy := daemon.NewDockerSocketProxyForTest(public, engine, life, func(context.Context) error {
		return nil
	})
	if err := proxy.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer proxy.Stop()

	var d net.Dialer
	conn, err := d.Dial("unix", public)
	if err != nil {
		t.Fatalf("dial public: %v", err)
	}
	defer conn.Close()
	time.Sleep(300 * time.Millisecond)
	if n := accepts.Load(); n != 0 {
		t.Fatalf("engine accepts=%d before HTTP request, want 0", n)
	}
	if _, err := conn.Write([]byte("GET /_ping HTTP/1.1\r\nHost: localhost\r\n\r\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	buf := make([]byte, 256)
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, err := conn.Read(buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !bytes.Contains(buf[:n], []byte("OK")) {
		t.Fatalf("response %q", buf[:n])
	}
	if accepts.Load() != 1 {
		t.Fatalf("engine accepts=%d after request, want 1", accepts.Load())
	}
}
