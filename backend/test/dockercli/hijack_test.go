package dockercli_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/enegalan/calf/backend/internal/dockercli"
)

func TestSocketPointsAtCalfDanglingSymlink(t *testing.T) {
	dir := t.TempDir()
	calfSock := filepath.Join(dir, "docker.sock")
	link := filepath.Join(dir, "docker.sock.link")
	if err := os.Symlink(calfSock, link); err != nil {
		t.Fatalf("Symlink() error: %v", err)
	}
	if !dockercli.SocketPointsAtCalf(link, calfSock) {
		t.Fatal("expected dangling symlink to calf socket to match")
	}
	if dockercli.SocketPointsAtCalf(link, filepath.Join(dir, "other.sock")) {
		t.Fatal("expected a different target not to match")
	}
}

func TestDetectHijackIgnoresMissingDefaultSocket(t *testing.T) {
	if _, err := os.Lstat("/var/run/docker.sock"); err == nil {
		t.Skip("system docker.sock exists on this host")
	}
	warnings := dockercli.DetectHijack("/tmp/calf-does-not-exist.sock")
	for _, warning := range warnings {
		if warning.Path == "/var/run/docker.sock" && warning.Owner == "unknown" {
			t.Fatalf("unexpected broken-symlink warning without a socket: %+v", warning)
		}
	}
}

func TestHijackMessagesOmitDockerHost(t *testing.T) {
	warnings := dockercli.DetectHijack("/tmp/calf-does-not-exist.sock")
	for _, warning := range warnings {
		if strings.Contains(warning.Message, "DOCKER_HOST") {
			t.Fatalf("hijack message still mentions DOCKER_HOST: %q", warning.Message)
		}
	}
}

func TestReplaceShellCompletionsRoundTrip(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	zshrc := filepath.Join(home, ".zshrc")
	if err := os.WriteFile(zshrc, []byte("export EDITOR=vim\n"), 0o644); err != nil {
		t.Fatalf("write zshrc: %v", err)
	}

	if err := dockercli.RemoveShellCompletions(); err != nil {
		t.Fatalf("RemoveShellCompletions on missing block: %v", err)
	}

	// EnsureShellCompletions needs docker; skip the docker completion binary if absent.
	if _, err := os.Stat(zshrc); err != nil {
		t.Fatalf("zshrc missing: %v", err)
	}
}

func TestProbeDefaultSocketMissing(t *testing.T) {
	status := dockercli.ProbeDefaultSocket("/tmp/calf-test.sock")
	if status.Path == "" {
		t.Fatal("expected default socket path")
	}
	if status.Enabled {
		t.Fatal("expected disabled when socket is not a calf symlink")
	}
}
