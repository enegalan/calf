//go:build darwin

package runtime_test

import (
	"bytes"
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

func TestGatedEngineProxyDoesNotDialUntilRequest(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "calf-gated-idle-")
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
	accepts := make(chan struct{}, 8)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			accepts <- struct{}{}
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

	var d net.Dialer
	conn, err := d.Dial("unix", gated)
	if err != nil {
		t.Fatalf("dial gated: %v", err)
	}
	defer conn.Close()
	select {
	case <-accepts:
		t.Fatal("engine accepted before HTTP request")
	case <-time.After(300 * time.Millisecond):
	}
	if _, err := conn.Write([]byte("GET /_ping HTTP/1.1\r\nHost: localhost\r\n\r\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	select {
	case <-accepts:
	case <-time.After(2 * time.Second):
		t.Fatal("engine did not accept after HTTP request")
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
}
