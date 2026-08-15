package daemon_test

import (
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

// TestProxyUnixConnectionUnblocksWhenPeerIgnoresHalfClose ensures a peer that
// never EOFs after CloseWrite cannot wedge the proxy forever (vsock leak).
func TestProxyUnixConnectionUnblocksWhenPeerIgnoresHalfClose(t *testing.T) {
	clientA, clientB := net.Pipe()
	serverA, serverB := net.Pipe()

	var ignoreHalfClose sync.WaitGroup
	ignoreHalfClose.Add(1)
	go func() {
		defer ignoreHalfClose.Done()
		buf := make([]byte, 32)
		// Read until the proxy fully closes the connection (not merely CloseWrite).
		for {
			_, err := serverB.Read(buf)
			if err != nil {
				return
			}
		}
	}()

	done := make(chan struct{})
	go func() {
		daemon.ProxyUnixConnectionForTest(clientA, serverA)
		close(done)
	}()

	_, _ = clientB.Write([]byte("ping"))
	_ = clientB.Close()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("proxyUnixConnection stuck after client close (half-close leak)")
	}
	ignoreHalfClose.Wait()
}
