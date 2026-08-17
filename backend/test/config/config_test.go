package config_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/enegalan/calf/backend/internal/config"
)

func TestLoadCreatesDefaultConfig(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("Load() error: %v", err)
	}

	defaults := config.Default()

	if cfg.ListenAddr != defaults.ListenAddr {
		t.Fatalf("expected listen_addr %q, got %q", defaults.ListenAddr, cfg.ListenAddr)
	}

	if cfg.LogLevel != defaults.LogLevel {
		t.Fatalf("expected log_level %q, got %q", defaults.LogLevel, cfg.LogLevel)
	}

	if !cfg.ShareHome {
		t.Fatal("expected share_home true by default")
	}

	path := filepath.Join(dir, ".config", "calf", "config.yaml")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("expected config file at %s: %v", path, err)
	}
}

func TestLoadReadsExistingConfig(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	configDir := filepath.Join(dir, ".config", "calf")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("MkdirAll() error: %v", err)
	}

	path := filepath.Join(configDir, "config.yaml")
	content := "listen_addr: \":9090\"\nlog_level: debug\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile() error: %v", err)
	}

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("Load() error: %v", err)
	}

	if cfg.ListenAddr != ":9090" {
		t.Fatalf("expected listen_addr :9090, got %q", cfg.ListenAddr)
	}

	if cfg.LogLevel != "debug" {
		t.Fatalf("expected log_level debug, got %q", cfg.LogLevel)
	}
}

func TestLoadMigratesAllInterfacesListenAddr(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	configDir := filepath.Join(dir, ".config", "calf")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("MkdirAll() error: %v", err)
	}

	path := filepath.Join(configDir, "config.yaml")
	content := "listen_addr: \":8765\"\nlog_level: info\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile() error: %v", err)
	}

	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("Load() error: %v", err)
	}

	want := config.Default().ListenAddr
	if cfg.ListenAddr != want {
		t.Fatalf("expected migrated listen_addr %q, got %q", want, cfg.ListenAddr)
	}
}

func TestParseFileShareList(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	home := config.HostHomeDir()
	shareHome, extras := config.ParseFileShareList([]string{home, "/tmp", home})
	if !shareHome {
		t.Fatal("expected home to be marked shared")
	}
	if len(extras) != 1 || extras[0] != "/tmp" {
		t.Fatalf("extras: %v", extras)
	}
	shareHome, extras = config.ParseFileShareList([]string{"/Volumes"})
	if shareHome {
		t.Fatal("home was not in the list")
	}
	if len(extras) != 1 || extras[0] != "/Volumes" {
		t.Fatalf("extras: %v", extras)
	}
}

func TestEffectiveFileShares(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	home := config.HostHomeDir()
	got := config.EffectiveFileShares(config.Config{ShareHome: true, FileShares: []string{"/tmp"}})
	if len(got) != 2 || got[0] != home || got[1] != "/tmp" {
		t.Fatalf("got %v want [%s /tmp]", got, home)
	}
	got = config.EffectiveFileShares(config.Config{ShareHome: false, FileShares: []string{"/tmp"}})
	if len(got) != 1 || got[0] != "/tmp" {
		t.Fatalf("got %v", got)
	}
}
