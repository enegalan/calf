package config_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/enegalan/calf/backend/internal/config"
)

func TestNormalizeLogLevel(t *testing.T) {
	cases := []struct {
		in      string
		want    string
		wantErr bool
	}{
		{in: "debug", want: "debug"},
		{in: "INFO", want: "info"},
		{in: "warning", want: "warn"},
		{in: "warn", want: "warn"},
		{in: "error", want: "error"},
		{in: "trace", wantErr: true},
		{in: "", wantErr: true},
	}
	for _, tc := range cases {
		got, err := config.NormalizeLogLevel(tc.in)
		if tc.wantErr {
			if err == nil {
				t.Fatalf("NormalizeLogLevel(%q) expected error", tc.in)
			}
			continue
		}
		if err != nil {
			t.Fatalf("NormalizeLogLevel(%q) error: %v", tc.in, err)
		}
		if got != tc.want {
			t.Fatalf("NormalizeLogLevel(%q)=%q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestReadLogTailMissingFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	text, path, err := config.ReadLogTail(1024)
	if err != nil {
		t.Fatalf("ReadLogTail() error: %v", err)
	}
	if text != "" {
		t.Fatalf("expected empty text, got %q", text)
	}
	wantPath := filepath.Join(dir, ".config", "calf", "logs", "calf.log")
	if path != wantPath {
		t.Fatalf("expected path %q, got %q", wantPath, path)
	}
}

func TestNewLoggerWritesFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	logger := config.NewLogger("info")
	logger.Info("hello from calf debug")

	text, path, err := config.ReadLogTail(4096)
	if err != nil {
		t.Fatalf("ReadLogTail() error: %v", err)
	}
	wantPath := filepath.Join(dir, ".config", "calf", "logs", "calf.log")
	if path != wantPath {
		t.Fatalf("expected path %q, got %q", wantPath, path)
	}
	if !strings.Contains(text, "hello from calf debug") {
		t.Fatalf("expected log file to contain message, got %q", text)
	}
}

func TestReadLogTailDropsPartialFirstLine(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	path, err := config.LogFilePath()
	if err != nil {
		t.Fatalf("LogFilePath() error: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll() error: %v", err)
	}
	content := "AAAA\nBBBB\nCCCC\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile() error: %v", err)
	}

	text, _, err := config.ReadLogTail(10)
	if err != nil {
		t.Fatalf("ReadLogTail() error: %v", err)
	}
	if strings.Contains(text, "AAAA") {
		t.Fatalf("expected partial first line to be dropped, got %q", text)
	}
	if !strings.Contains(text, "CCCC") {
		t.Fatalf("expected last line to be kept, got %q", text)
	}
}

func TestClearLogFileRemovesContentsAndRotatedBackup(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	logger := config.NewLogger("info")
	logger.Info("hello from calf debug")

	path, err := config.LogFilePath()
	if err != nil {
		t.Fatalf("LogFilePath() error: %v", err)
	}
	if err := os.WriteFile(path+".1", []byte("rotated\n"), 0o644); err != nil {
		t.Fatalf("WriteFile rotated backup error: %v", err)
	}

	if err := config.ClearLogFile(); err != nil {
		t.Fatalf("ClearLogFile() error: %v", err)
	}

	text, _, err := config.ReadLogTail(4096)
	if err != nil {
		t.Fatalf("ReadLogTail() error: %v", err)
	}
	if strings.Contains(text, "hello from calf debug") {
		t.Fatalf("expected cleared log to drop previous lines, got %q", text)
	}
	if _, err := os.Stat(path + ".1"); !os.IsNotExist(err) {
		t.Fatalf("expected rotated backup to be removed, got %v", err)
	}

	logger.Info("after clear")
	text, _, err = config.ReadLogTail(4096)
	if err != nil {
		t.Fatalf("ReadLogTail after write error: %v", err)
	}
	if !strings.Contains(text, "after clear") {
		t.Fatalf("expected new lines after clear, got %q", text)
	}
	if strings.Contains(text, "hello from calf debug") {
		t.Fatalf("expected previous lines to stay gone, got %q", text)
	}
}
