package runtime_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestResolveNativeDockerSocketPrefersRootless(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	t.Setenv("HOME", t.TempDir())

	socketPath := filepath.Join(dir, "docker.sock")
	if err := os.WriteFile(socketPath, nil, 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	socket, rootless := runtime.ResolveNativeDockerSocket("", true)
	if !rootless {
		t.Fatalf("expected rootless=true")
	}
	if socket != socketPath {
		t.Fatalf("expected socket %q, got %q", socketPath, socket)
	}
}

func TestResolveNativeDockerSocketFallsBackToSystem(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	t.Setenv("HOME", t.TempDir())

	socket, rootless := runtime.ResolveNativeDockerSocket("", true)
	if rootless {
		t.Fatalf("expected rootless=false when no user socket exists")
	}
	if socket != "/var/run/docker.sock" {
		t.Fatalf("expected system socket, got %q", socket)
	}
}

func TestResolveNativeDockerSocketExplicitWins(t *testing.T) {
	explicit := "/custom/docker.sock"
	socket, rootless := runtime.ResolveNativeDockerSocket(explicit, true)
	if socket != explicit {
		t.Fatalf("expected %q, got %q", explicit, socket)
	}
	if rootless {
		t.Fatalf("expected rootless=false for custom path outside user dirs")
	}
}

func TestResolveNativeDockerSocketRootlessDisabled(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	t.Setenv("HOME", t.TempDir())

	socketPath := filepath.Join(dir, "docker.sock")
	if err := os.WriteFile(socketPath, nil, 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	socket, rootless := runtime.ResolveNativeDockerSocket("", false)
	if rootless {
		t.Fatalf("expected rootless=false when preference disabled")
	}
	if socket != "/var/run/docker.sock" {
		t.Fatalf("expected system socket, got %q", socket)
	}
}

func TestNewNativeUsesResolvedSocket(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	t.Setenv("HOME", t.TempDir())

	socketPath := filepath.Join(dir, "docker.sock")
	if err := os.WriteFile(socketPath, nil, 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	native := runtime.NewNative("", "", 0, 0, 0, 0, true, runtime.ProxyConfig{})
	if native.DockerSocket() != socketPath {
		t.Fatalf("expected %q, got %q", socketPath, native.DockerSocket())
	}

	status, _ := native.Status(context.Background())
	if !status.Rootless {
		t.Fatalf("expected Status.Rootless=true, got %#v", status)
	}
}
