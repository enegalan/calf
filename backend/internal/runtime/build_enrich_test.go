package runtime

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNormalizeDockerfilePathUsesExistingRelativePath(t *testing.T) {
	dir := t.TempDir()
	dockerfile := filepath.Join(dir, "Dockerfile")
	if err := os.WriteFile(dockerfile, []byte("FROM alpine"), 0o644); err != nil {
		t.Fatalf("WriteFile() error: %v", err)
	}

	got := NormalizeDockerfilePath(dir, "examples/hello-world/Dockerfile")
	if got != "Dockerfile" {
		t.Fatalf("expected Dockerfile, got %q", got)
	}
}

func TestParseImageRefFromBuildLog(t *testing.T) {
	rawLog := `#5 naming to docker.io/library/calf-sync-test:latest done
#6 naming to docker.io/library/toth-api:latest 0.0s done`

	got := ParseImageRefFromBuildLog(rawLog)
	if got != "toth-api:latest" {
		t.Fatalf("expected toth-api:latest, got %q", got)
	}
}
