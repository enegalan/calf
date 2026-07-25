package runtime_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestNormalizeDockerfilePathUsesExistingRelativePath(t *testing.T) {
	dir := t.TempDir()
	dockerfile := filepath.Join(dir, "Dockerfile")
	if err := os.WriteFile(dockerfile, []byte("FROM alpine"), 0o644); err != nil {
		t.Fatalf("WriteFile() error: %v", err)
	}

	got := runtime.NormalizeDockerfilePath(dir, "examples/hello-world/Dockerfile")
	if got != "Dockerfile" {
		t.Fatalf("expected Dockerfile, got %q", got)
	}
}

func TestParseImageRefFromBuildLog(t *testing.T) {
	rawLog := `#5 naming to docker.io/library/calf-sync-test:latest done
#6 naming to docker.io/library/toth-api:latest 0.0s done`

	got := runtime.ParseImageRefFromBuildLog(rawLog)
	if got != "toth-api:latest" {
		t.Fatalf("expected toth-api:latest, got %q", got)
	}
}

func TestDigestFromInspectFieldsUsesRepoDigests(t *testing.T) {
	got := runtime.DigestFromInspectFields(
		"",
		[]string{"docker.io/library/ubuntu@sha256:abcdef"},
		"sha256:imageid",
	)
	if got != "sha256:abcdef" {
		t.Fatalf("expected sha256:abcdef, got %q", got)
	}
}
