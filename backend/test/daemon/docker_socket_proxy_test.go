package daemon_test

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
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
	proxy := daemon.NewDockerSocketProxyForTest(
		public,
		engine,
		context.Background(),
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

// TestDockerSocketProxyRebindReplacesSymlink restores a real socket after hand-off damage.
func TestDockerSocketProxyRebindReplacesSymlink(t *testing.T) {
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

	proxy := daemon.NewDockerSocketProxyForTest(public, engine, context.Background(), func(context.Context) error {
		return nil
	})
	if err := proxy.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer proxy.Stop()

	// Simulate a raced daemon quit that replaced the public path with a symlink.
	_ = os.Remove(public)
	if err := os.Symlink(engine, public); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(public)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("expected symlink before rebind")
	}

	if err := proxy.Rebind(); err != nil {
		t.Fatalf("Rebind: %v", err)
	}
	info, err = os.Lstat(public)
	if err != nil {
		t.Fatalf("Lstat after rebind: %v", err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("public path still a symlink")
	}
	if info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("public path is not a socket")
	}
}
