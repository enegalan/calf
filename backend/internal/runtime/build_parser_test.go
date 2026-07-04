package runtime

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseBuildOutputSteps(t *testing.T) {
	output := `#1 [internal] load build definition from Dockerfile
#1 DONE 0.0s

#2 [internal] load metadata for docker.io/library/alpine:latest
#2 DONE 0.7s

#3 [internal] load .dockerignore
#3 transferring context: 1.1kB done
#3 DONE 0.0s

#4 [1/3] FROM docker.io/library/alpine:latest
#4 CACHED

#5 [2/3] RUN apk add --no-cache nginx
#5 CACHED

#6 [3/3] COPY demo-app/ ./
#6 DONE 0.3s
`

	result := ParseBuildOutput(output)

	if len(result.Steps) < 4 {
		t.Fatalf("expected at least 4 steps, got %d", len(result.Steps))
	}

	if result.CachedSteps < 2 {
		t.Fatalf("expected at least 2 cached steps, got %d", result.CachedSteps)
	}

	foundCopy := false
	for _, step := range result.Steps {
		if strings.Contains(step.Name, "COPY demo-app") {
			foundCopy = true
			if step.Cached {
				t.Fatalf("expected COPY step to not be cached")
			}
			if step.DurationMs <= 0 {
				t.Fatalf("expected COPY step duration")
			}
		}
	}

	if !foundCopy {
		t.Fatalf("expected COPY step in parsed output")
	}

	if result.Timing.ImagePullsMs <= 0 {
		t.Fatalf("expected image pull timing from metadata step")
	}

	foundDockerignore := false
	for _, step := range result.Steps {
		if strings.Contains(step.Name, "load .dockerignore") {
			foundDockerignore = true
			if strings.Contains(step.Name, "transferring context") {
				t.Fatalf("expected dockerignore step name to stay on header, got %q", step.Name)
			}
		}
	}
	if !foundDockerignore {
		t.Fatalf("expected dockerignore step in parsed output")
	}
}

func TestApplyBuildLogsPopulatesTiming(t *testing.T) {
	build := Build{Steps: []BuildStep{}}
	logs := `#1 [internal] load build definition from Dockerfile
#1 DONE 0.0s

#2 [internal] load metadata for docker.io/library/alpine:latest
#2 DONE 0.7s

#3 [2/3] RUN apk add --no-cache nginx
#3 DONE 1.2s
`

	ApplyBuildLogs(&build, logs)

	if len(build.Steps) != 3 {
		t.Fatalf("expected 3 steps, got %d", len(build.Steps))
	}

	if build.Timing.ImagePullsMs <= 0 {
		t.Fatalf("expected image pull timing, got %+v", build.Timing)
	}

	if build.Timing.ExecutionsMs <= 0 {
		t.Fatalf("expected execution timing, got %+v", build.Timing)
	}
}

func TestParseDockerfileDependencies(t *testing.T) {
	dir := t.TempDir()
	dockerfile := filepath.Join(dir, "Dockerfile")
	content := "FROM php:8.4-fpm-alpine\nFROM node:20 AS assets\nCOPY . .\n"
	if err := os.WriteFile(dockerfile, []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile() error: %v", err)
	}

	deps := parseDockerfileDependencies(dir, "Dockerfile", "linux/arm64")
	if len(deps) != 2 {
		t.Fatalf("expected 2 dependencies, got %d", len(deps))
	}

	if deps[0].Source != "php:8.4-fpm-alpine" {
		t.Fatalf("unexpected first dependency: %q", deps[0].Source)
	}
}

func TestReadBuildSourceRejectsTraversal(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "Dockerfile"), []byte("FROM alpine"), 0o644); err != nil {
		t.Fatalf("WriteFile() error: %v", err)
	}

	_, err := ReadBuildSource(dir, "../Dockerfile", "linux/arm64")
	if err == nil {
		t.Fatalf("expected path traversal to be rejected")
	}
}
