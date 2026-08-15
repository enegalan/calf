package dockercli_test

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/enegalan/calf/backend/internal/dockercli"
)

func TestEnsureCLIPluginsRepairsBrokenSymlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink repair covered on unix")
	}

	home := t.TempDir()
	t.Setenv("HOME", home)

	pluginsDir := filepath.Join(home, ".docker", "cli-plugins")
	if err := os.MkdirAll(pluginsDir, 0o755); err != nil {
		t.Fatalf("MkdirAll plugins: %v", err)
	}

	goodDir := t.TempDir()
	goodBuildx := filepath.Join(goodDir, "docker-buildx")
	goodCompose := filepath.Join(goodDir, "docker-compose")
	writeExecutable(t, goodBuildx)
	writeExecutable(t, goodCompose)

	t.Setenv("PATH", goodDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	brokenBuildx := filepath.Join(pluginsDir, "docker-buildx")
	if err := os.Symlink(filepath.Join(home, "missing-docker-buildx"), brokenBuildx); err != nil {
		t.Fatalf("Symlink broken buildx: %v", err)
	}
	brokenCompose := filepath.Join(pluginsDir, "docker-compose")
	if err := os.Symlink(filepath.Join(home, "missing-docker-compose"), brokenCompose); err != nil {
		t.Fatalf("Symlink broken compose: %v", err)
	}

	before := dockercli.ProbePlugins()
	if before.BuildxAvailable || before.ComposeAvailable {
		t.Fatalf("expected broken plugins before repair, got %+v", before)
	}

	status, repaired, err := dockercli.EnsureCLIPlugins()
	if err != nil {
		t.Fatalf("EnsureCLIPlugins() error: %v", err)
	}
	if !status.BuildxAvailable || !status.ComposeAvailable {
		t.Fatalf("expected repaired plugins, got %+v", status)
	}
	if len(repaired) == 0 {
		t.Fatalf("expected repaired plugin names, got none")
	}
	if status.Hint != "" {
		t.Fatalf("expected empty hint after successful repair, got %q", status.Hint)
	}

	resolved, err := filepath.EvalSymlinks(brokenBuildx)
	if err != nil {
		t.Fatalf("EvalSymlinks buildx: %v", err)
	}
	want, err := filepath.EvalSymlinks(goodBuildx)
	if err != nil {
		t.Fatalf("EvalSymlinks want: %v", err)
	}
	if resolved != want {
		t.Fatalf("buildx linked to %q, want %q", resolved, want)
	}
}

func TestEnsureCLIPluginsIdempotentWhenHealthy(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink repair covered on unix")
	}

	home := t.TempDir()
	t.Setenv("HOME", home)

	pluginsDir := filepath.Join(home, ".docker", "cli-plugins")
	if err := os.MkdirAll(pluginsDir, 0o755); err != nil {
		t.Fatalf("MkdirAll plugins: %v", err)
	}

	goodDir := t.TempDir()
	for _, name := range []string{"docker-buildx", "docker-compose"} {
		target := filepath.Join(goodDir, name)
		writeExecutable(t, target)
		if err := os.Symlink(target, filepath.Join(pluginsDir, name)); err != nil {
			t.Fatalf("Symlink %s: %v", name, err)
		}
	}
	t.Setenv("PATH", goodDir)

	status, repaired, err := dockercli.EnsureCLIPlugins()
	if err != nil {
		t.Fatalf("EnsureCLIPlugins() error: %v", err)
	}
	if !status.BuildxAvailable || !status.ComposeAvailable {
		t.Fatalf("expected plugins available, got %+v", status)
	}
	if len(repaired) != 0 {
		t.Fatalf("did not expect repairs for healthy plugins: %v", repaired)
	}
}

func writeExecutable(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("WriteFile %s: %v", path, err)
	}
}
