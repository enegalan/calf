package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadCreatesDefaultConfig(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error: %v", err)
	}

	if cfg.ListenAddr != DefaultListenAddr {
		t.Fatalf("expected listen_addr %q, got %q", DefaultListenAddr, cfg.ListenAddr)
	}

	if cfg.LogLevel != DefaultLogLevel {
		t.Fatalf("expected log_level %q, got %q", DefaultLogLevel, cfg.LogLevel)
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

	cfg, err := Load()
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
