package buildhistory_test

import (
	"path/filepath"
	"testing"

	"github.com/enegalan/calf/backend/internal/buildhistory"
)

func TestParseInspectDetailAbsoluteContext(t *testing.T) {
	output := `{
		"Context": "/Users/demo/project",
		"Dockerfile": "Dockerfile.dev"
	}`

	detail, err := buildhistory.ParseInspectDetail(output)
	if err != nil {
		t.Fatalf("ParseInspectDetail() error: %v", err)
	}

	if detail.Context != "/Users/demo/project" {
		t.Fatalf("expected context /Users/demo/project, got %q", detail.Context)
	}
	if detail.Dockerfile != "Dockerfile.dev" {
		t.Fatalf("expected dockerfile Dockerfile.dev, got %q", detail.Dockerfile)
	}
}

func TestParseInspectDetailComposeLabelsArray(t *testing.T) {
	workingDir := t.TempDir()

	output := `{
		"Context": ".",
		"Dockerfile": "Dockerfile",
		"Labels": [
			{"Name": "com.docker.compose.project.working_dir", "Value": "` + filepath.ToSlash(workingDir) + `"},
			{"Name": "com.docker.compose.project", "Value": "compose-app"}
		]
	}`

	detail, err := buildhistory.ParseInspectDetail(output)
	if err != nil {
		t.Fatalf("ParseInspectDetail() error: %v", err)
	}

	if detail.Context != workingDir {
		t.Fatalf("expected compose working dir context %q, got %q", workingDir, detail.Context)
	}
	if detail.Labels["com.docker.compose.project"] != "compose-app" {
		t.Fatalf("expected compose project label, got %v", detail.Labels)
	}
}
