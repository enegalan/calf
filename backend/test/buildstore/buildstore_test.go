package buildstore_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/enegalan/calf/backend/internal/buildstore"
	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestSaveAndLoadBuilds(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	builds := []runtime.Build{
		{
			ID:        "build-1",
			Tag:       "demo:latest",
			Context:   "/tmp/demo",
			Status:    "success",
			CreatedAt: "2026-01-01T00:00:00Z",
			Builder:   "default",
			Steps:     []runtime.BuildStep{},
		},
	}

	if err := buildstore.Save(builds, 1); err != nil {
		t.Fatalf("Save() error: %v", err)
	}

	path := filepath.Join(dir, ".config", "calf", "builds.json")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("expected builds file at %s: %v", path, err)
	}

	file, err := buildstore.Load()
	if err != nil {
		t.Fatalf("Load() error: %v", err)
	}

	if file.Seq != 1 {
		t.Fatalf("expected seq 1, got %d", file.Seq)
	}

	if len(file.Builds) != 1 || file.Builds[0].ID != "build-1" {
		t.Fatalf("unexpected builds: %+v", file.Builds)
	}
}
