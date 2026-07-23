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

func TestParseTarTvOutputSizeAndModifiedVariants(t *testing.T) {
	cases := []struct {
		name             string
		line             string
		wantName         string
		wantSize         int64
		wantModified     string
		wantDir          bool
		wantNoteContains string
	}{
		{
			name:         "busybox",
			line:         "-rw-r--r--  0 0 0 12 Jan 1 00:00 /app/package.json",
			wantName:     "package.json",
			wantSize:     12,
			wantModified: "Jan 1 00:00",
		},
		{
			name:         "gnu",
			line:         "-rw-r--r-- root/root 4096 2024-01-15 12:30 /app/data.bin",
			wantName:     "data.bin",
			wantSize:     4096,
			wantModified: "2024-01-15 12:30",
		},
		{
			name:         "bsd",
			line:         "-rw-r--r--  1 user group 2048 Jan  2 13:45 /app/readme.txt",
			wantName:     "readme.txt",
			wantSize:     2048,
			wantModified: "Jan 2 13:45",
		},
		{
			name:             "symlink",
			line:             "lrwxrwxrwx  0 0 0 11 Jan 1 00:00 /app/link -> /etc/hosts",
			wantName:         "link",
			wantSize:         11,
			wantModified:     "Jan 1 00:00",
			wantNoteContains: "/etc/hosts",
		},
		{
			name:         "directory",
			line:         "drwxr-xr-x  0 0 0 0 Jan 1 00:00 /app/subdir/",
			wantName:     "subdir",
			wantSize:     0,
			wantModified: "Jan 1 00:00",
			wantDir:      true,
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			entries := runtime.ParseTarTvOutput("/app", []byte(testCase.line))
			if len(entries) != 1 {
				t.Fatalf("expected 1 entry, got %d", len(entries))
			}
			entry := entries[0]
			if entry.Name != testCase.wantName {
				t.Fatalf("name: got %q want %q", entry.Name, testCase.wantName)
			}
			if entry.Size != testCase.wantSize {
				t.Fatalf("size: got %d want %d", entry.Size, testCase.wantSize)
			}
			if entry.Modified != testCase.wantModified {
				t.Fatalf("modified: got %q want %q", entry.Modified, testCase.wantModified)
			}
			if entry.IsDir != testCase.wantDir {
				t.Fatalf("isDir: got %v want %v", entry.IsDir, testCase.wantDir)
			}
			if testCase.wantNoteContains != "" && !strings.Contains(entry.Note, testCase.wantNoteContains) {
				t.Fatalf("note %q missing %q", entry.Note, testCase.wantNoteContains)
			}
		})
	}
}
