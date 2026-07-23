package runtime_test

import (
	"errors"
	"strings"
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestIsContainerNotRunningError(t *testing.T) {
	err := errors.New("Error response from daemon: container abc is not running")
	if !runtime.IsContainerNotRunningError(err) {
		t.Fatal("expected not-running detection")
	}
}

func TestIsContainerNotFoundError(t *testing.T) {
	err := errors.New("error: no such object: 5bd242b09030")
	if !runtime.IsContainerNotFoundError(err) {
		t.Fatal("expected not-found detection")
	}
}

func TestParseTarTvOutputRootAbsolutePaths(t *testing.T) {
	tarOutput := strings.Join([]string{
		"drwxr-xr-x  0 0 0 0 Jan 1 00:00 /",
		"-rwxr-xr-x  0 0 0 0 Jan 1 00:00 /.dockerenv",
		"drwxr-xr-x  0 0 0 0 Jan 1 00:00 /app/",
		"-rw-r--r--  0 0 0 12 Jan 1 00:00 /app/package.json",
		"drwxr-xr-x  0 0 0 0 Jan 1 00:00 /etc/",
	}, "\n")

	entries := runtime.ParseTarTvOutput("/", []byte(tarOutput))
	names := map[string]bool{}
	for _, entry := range entries {
		names[entry.Name] = true
	}
	if !names[".dockerenv"] || !names["app"] || !names["etc"] {
		t.Fatalf("unexpected root entries: %v", names)
	}
	if names[""] || len(entries) != 3 {
		t.Fatalf("expected 3 root children, got %d %v", len(entries), names)
	}
}
