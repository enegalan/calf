package migration

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGroupContainersByComposeProject(t *testing.T) {
	inspects := []containerInspect{
		{
			Name: "/typing-app-backend",
			Config: struct {
				Image      string            `json:"Image"`
				Env        []string          `json:"Env"`
				Cmd        []string          `json:"Cmd"`
				Entrypoint []string          `json:"Entrypoint"`
				WorkingDir string            `json:"WorkingDir"`
				Hostname   string            `json:"Hostname"`
				User       string            `json:"User"`
				Labels     map[string]string `json:"Labels"`
			}{
				Image: "keycode-backend:latest",
				Labels: map[string]string{
					composeProjectLabel:     "keycode",
					composeServiceLabel:     "backend",
					composeWorkingDirLabel:  "/Users/test/keycode",
					composeConfigFilesLabel: "/Users/test/keycode/docker-compose.yml",
				},
			},
		},
		{
			Name: "/standalone",
			Config: struct {
				Image      string            `json:"Image"`
				Env        []string          `json:"Env"`
				Cmd        []string          `json:"Cmd"`
				Entrypoint []string          `json:"Entrypoint"`
				WorkingDir string            `json:"WorkingDir"`
				Hostname   string            `json:"Hostname"`
				User       string            `json:"User"`
				Labels     map[string]string `json:"Labels"`
			}{
				Image: "alpine:latest",
			},
		},
	}

	groups, standalone := groupContainersByComposeProject(inspects, map[string]bool{
		"typing-app-backend": true,
		"standalone":         false,
	})

	if len(groups) != 1 {
		t.Fatalf("expected 1 compose group, got %d", len(groups))
	}

	if groups[0].Name != "keycode" {
		t.Fatalf("expected project keycode, got %q", groups[0].Name)
	}

	if len(groups[0].Containers) != 1 {
		t.Fatalf("expected 1 container in group, got %d", len(groups[0].Containers))
	}

	if len(standalone) != 1 || standalone[0].Name != "/standalone" {
		t.Fatalf("expected standalone container, got %#v", standalone)
	}
}

func TestPatchComposeForMigration(t *testing.T) {
	dir := t.TempDir()
	composePath := filepath.Join(dir, "docker-compose.yml")
	compose := `services:
  backend:
    build:
      context: ./backend
    container_name: typing-app-backend
  frontend:
    image: keycode-frontend:latest
`
	if err := os.WriteFile(composePath, []byte(compose), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := patchComposeForMigration(composePath, map[string]string{
		"backend": "keycode-backend:latest",
	}); err != nil {
		t.Fatal(err)
	}

	patched, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatal(err)
	}

	content := string(patched)
	if strings.Contains(content, "build:") {
		t.Fatalf("expected build removed, got %s", content)
	}

	if !strings.Contains(content, "image: keycode-backend:latest") {
		t.Fatalf("expected backend image patched, got %s", content)
	}
}

func TestMigrationLabelsPreservesComposeMetadata(t *testing.T) {
	inspect := containerInspect{
		Config: struct {
			Image      string            `json:"Image"`
			Env        []string          `json:"Env"`
			Cmd        []string          `json:"Cmd"`
			Entrypoint []string          `json:"Entrypoint"`
			WorkingDir string            `json:"WorkingDir"`
			Hostname   string            `json:"Hostname"`
			User       string            `json:"User"`
			Labels     map[string]string `json:"Labels"`
		}{
			Labels: map[string]string{
				composeProjectLabel: "keycode",
				composeServiceLabel: "backend",
				"empty":               "",
			},
		},
	}

	labels := migrationLabels(inspect)
	if len(labels) != 2 {
		t.Fatalf("expected 2 labels, got %d", len(labels))
	}

	if labels[0][0] != composeProjectLabel || labels[0][1] != "keycode" {
		t.Fatalf("unexpected first label: %#v", labels[0])
	}
}

func TestContainerBindMountsUsesVolumeName(t *testing.T) {
	inspect := containerInspect{
		Mounts: []struct {
			Type        string `json:"Type"`
			Name        string `json:"Name"`
			Source      string `json:"Source"`
			Destination string `json:"Destination"`
			Mode        string `json:"Mode"`
			RW          bool   `json:"RW"`
		}{
			{
				Type:        "volume",
				Name:        "keycode_mongodb_data",
				Destination: "/data/db",
				RW:          true,
			},
		},
	}

	binds := containerBindMounts(inspect)
	if len(binds) != 1 || binds[0] != "keycode_mongodb_data:/data/db" {
		t.Fatalf("unexpected binds: %#v", binds)
	}
}
