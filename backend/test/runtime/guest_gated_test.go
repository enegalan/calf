//go:build darwin

package runtime_test

import (
	"context"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestGatedEngineProxyForwardsPing(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "calf-gated-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
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

	gated, stop, err := runtime.StartGatedEngineProxyForTest(engine)
	if err != nil {
		t.Fatalf("StartGatedEngineProxyForTest: %v", err)
	}
	defer stop()

	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", gated)
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
}
