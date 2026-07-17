package runtime_test

import (
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestBuildxBuildArgs(t *testing.T) {
	args := runtime.BuildxBuildArgs("app:latest", "Dockerfile.dev", "linux/amd64", "/tmp/ctx")
	want := []string{
		"buildx", "build", "--progress=plain", "--load", "-t", "app:latest",
		"-f", "Dockerfile.dev",
		"--platform", "linux/amd64",
		"/tmp/ctx",
	}
	if len(args) != len(want) {
		t.Fatalf("len=%d want %d (%v)", len(args), len(want), args)
	}
	for i := range want {
		if args[i] != want[i] {
			t.Fatalf("args[%d]=%q want %q", i, args[i], want[i])
		}
	}
}
