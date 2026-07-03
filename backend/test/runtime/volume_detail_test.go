package runtime_test

import (
	"context"
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestListFilesAtPathUsesLsOutput(t *testing.T) {
	runner := func(_ context.Context, command string, args ...string) ([]byte, error) {
		if command == "ls" && len(args) == 2 && args[0] == "-la" && args[1] == "/data/vol" {
			return []byte(`total 4
-rw------- 1 root root 88 Jan  1 12:00 dump.rdb
`), nil
		}

		t.Fatalf("unexpected command: %s %v", command, args)
		return nil, nil
	}

	entries, err := runtime.ListFilesAtPath(context.Background(), runner, "/data/vol", "/")
	if err != nil {
		t.Fatalf("ListFilesAtPath() error: %v", err)
	}

	if len(entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(entries))
	}

	if entries[0].Name != "dump.rdb" {
		t.Fatalf("expected dump.rdb, got %q", entries[0].Name)
	}

	if entries[0].Path != "/dump.rdb" {
		t.Fatalf("expected /dump.rdb, got %q", entries[0].Path)
	}
}

func TestListFilesAtPathFallsBackToSudo(t *testing.T) {
	calls := 0
	runner := func(_ context.Context, command string, args ...string) ([]byte, error) {
		calls++
		if command == "ls" {
			return nil, context.Canceled
		}

		if command == "sudo" && len(args) == 3 && args[0] == "ls" {
			return []byte(`total 0
`), nil
		}

		t.Fatalf("unexpected command: %s %v", command, args)
		return nil, nil
	}

	entries, err := runtime.ListFilesAtPath(context.Background(), runner, "/data/vol", "/")
	if err != nil {
		t.Fatalf("ListFilesAtPath() error: %v", err)
	}

	if calls != 2 {
		t.Fatalf("expected 2 calls, got %d", calls)
	}

	if len(entries) != 0 {
		t.Fatalf("expected empty directory, got %d entries", len(entries))
	}
}
