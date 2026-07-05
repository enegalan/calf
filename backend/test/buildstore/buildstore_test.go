package buildstore_test

import (
	"fmt"
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

func TestSaveTrimBuildsRetainsNewest(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	builds := make([]runtime.Build, 0, 210)
	for index := 1; index <= 210; index++ {
		builds = append([]runtime.Build{{
			ID:        fmt.Sprintf("build-%d", index),
			Tag:       fmt.Sprintf("demo:%d", index),
			Context:   "/tmp/demo",
			Status:    "success",
			CreatedAt: fmt.Sprintf("2026-01-01T00:00:%02dZ", index%60),
			Builder:   "default",
			Steps:     []runtime.BuildStep{},
		}}, builds...)
	}

	if err := buildstore.Save(builds, 210); err != nil {
		t.Fatalf("Save() error: %v", err)
	}

	file, err := buildstore.Load()
	if err != nil {
		t.Fatalf("Load() error: %v", err)
	}

	if len(file.Builds) != 200 {
		t.Fatalf("expected 200 builds, got %d", len(file.Builds))
	}

	if file.Builds[0].ID != "build-210" {
		t.Fatalf("expected newest build first, got %q", file.Builds[0].ID)
	}

	if file.Builds[len(file.Builds)-1].ID != "build-11" {
		t.Fatalf("expected oldest retained build-11, got %q", file.Builds[len(file.Builds)-1].ID)
	}
}
