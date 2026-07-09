package dockercli_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/enegalan/calf/backend/internal/dockercli"
)

func TestReadCurrentContextMissingFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	status, err := dockercli.StatusFor("", false)
	if err != nil {
		t.Fatalf("StatusFor() error: %v", err)
	}

	if status.CurrentContext != "" {
		t.Fatalf("expected empty context, got %q", status.CurrentContext)
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

	status, err := dockercli.StatusFor("", false)
	if err != nil {
		t.Fatalf("StatusFor() error: %v", err)
	}

	if status.CurrentContext != "calf" {
		t.Fatalf("expected calf, got %q", status.CurrentContext)
	}
}
