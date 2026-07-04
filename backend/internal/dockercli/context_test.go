package dockercli

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadCurrentContextMissingFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	if got := readCurrentContext(); got != "" {
		t.Fatalf("expected empty context, got %q", got)
	}
}

func TestReadCurrentContextFromConfig(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	dockerDir := filepath.Join(dir, ".docker")
	if err := os.MkdirAll(dockerDir, 0o755); err != nil {
		t.Fatalf("MkdirAll() error: %v", err)
	}

	content := `{"currentContext":"calf"}`
	if err := os.WriteFile(filepath.Join(dockerDir, "config.json"), []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile() error: %v", err)
	}

	if got := readCurrentContext(); got != "calf" {
		t.Fatalf("expected calf, got %q", got)
	}
}
