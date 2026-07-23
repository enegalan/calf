package runtime_test

import (
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestParseContainerLines(t *testing.T) {
	t.Helper()

	output := []byte(`{"ID":"abc","Names":"toth-postgres-1","Image":"postgres:16-alpine","State":"","Status":"Up 2 hours","CreatedAt":"2026-01-01T00:00:00Z","Ports":"0.0.0.0:5432->5432/tcp","Labels":{"com.docker.compose.project":"toth","com.docker.compose.service":"postgres"}}
`)

	containers, err := runtime.ParseContainerLines(output)
	if err != nil {
		t.Fatalf("ParseContainerLines() error: %v", err)
	}

	if len(containers) != 1 {
		t.Fatalf("expected 1 container, got %d", len(containers))
	}

	if containers[0].Name != "toth-postgres-1" {
		t.Fatalf("expected container name toth-postgres-1, got %q", containers[0].Name)
	}

	if containers[0].State != "running" {
		t.Fatalf("expected state running, got %q", containers[0].State)
	}

	if containers[0].ComposeProject != "toth" {
		t.Fatalf("expected compose project toth, got %q", containers[0].ComposeProject)
	}

	if containers[0].ComposeService != "postgres" {
		t.Fatalf("expected compose service postgres, got %q", containers[0].ComposeService)
	}

	if containers[0].Ports != "0.0.0.0:5432->5432/tcp" {
		t.Fatalf("expected ports, got %q", containers[0].Ports)
	}
}

func TestParseContainerLinesSkipsEmptyNames(t *testing.T) {
	output := []byte(`{"ID":"5bd242b09030","Names":"","Image":"alpine","Status":"Exited (0) 4 days ago","Ports":"","Labels":{}}
{"ID":"abc123","Names":"ok","Image":"alpine","Status":"Exited (0) 1 hour ago","Ports":"","Labels":{}}
`)

	containers, err := runtime.ParseContainerLines(output)
	if err != nil {
		t.Fatalf("ParseContainerLines() error: %v", err)
	}

	if len(containers) != 1 {
		t.Fatalf("expected 1 container, got %d", len(containers))
	}

	if containers[0].ID != "abc123" {
		t.Fatalf("expected abc123, got %q", containers[0].ID)
	}
}

func TestParseContainerLinesInfersComposeFromName(t *testing.T) {
	output := []byte(`{"ID":"def","Names":"p2p-lan-coturn-1","Image":"coturn/coturn:latest","Status":"Created","Ports":"","Labels":{}}
`)

	containers, err := runtime.ParseContainerLines(output)
	if err != nil {
		t.Fatalf("ParseContainerLines() error: %v", err)
	}

	if containers[0].ComposeProject != "p2p-lan" {
		t.Fatalf("expected compose project p2p-lan, got %q", containers[0].ComposeProject)
	}

	if containers[0].ComposeService != "coturn" {
		t.Fatalf("expected compose service coturn, got %q", containers[0].ComposeService)
	}
}

func TestParseContainerLinesInfersComposeFromSharedPrefix(t *testing.T) {
	output := []byte(`{"ID":"a1","Names":"p2p-lan","Image":"p2p-lan-p2p-lan:latest","Status":"Up","Ports":"0.0.0.0:3030->3030/tcp","Labels":{}}
{"ID":"a2","Names":"p2p-lan-coturn","Image":"coturn/coturn:latest","Status":"Up","Ports":"","Labels":{}}
`)

	containers, err := runtime.ParseContainerLines(output)
	if err != nil {
		t.Fatalf("ParseContainerLines() error: %v", err)
	}

	if len(containers) != 2 {
		t.Fatalf("expected 2 containers, got %d", len(containers))
	}

	byName := map[string]runtime.Container{}
	for _, container := range containers {
		byName[container.Name] = container
	}

	for _, name := range []string{"p2p-lan", "p2p-lan-coturn"} {
		container := byName[name]
		if container.ComposeProject != "p2p-lan" {
			t.Fatalf("%s: expected compose project p2p-lan, got %q", name, container.ComposeProject)
		}
	}

	if byName["p2p-lan"].ComposeService != "p2p-lan" {
		t.Fatalf("expected compose service p2p-lan, got %q", byName["p2p-lan"].ComposeService)
	}

	if byName["p2p-lan-coturn"].ComposeService != "coturn" {
		t.Fatalf("expected compose service coturn, got %q", byName["p2p-lan-coturn"].ComposeService)
	}
}

func TestParseContainerLinesInfersComposeFromTypingAppPrefix(t *testing.T) {
	output := []byte(`{"ID":"b1","Names":"typing-app-backend","Image":"docker.io/library/keycode-backend:latest","Status":"Up","Ports":"","Labels":{}}
{"ID":"b2","Names":"typing-app-frontend","Image":"docker.io/library/keycode-frontend:latest","Status":"Up","Ports":"","Labels":{}}
{"ID":"b3","Names":"typing-app-mongodb","Image":"docker.io/library/mongo:7.0","Status":"Up","Ports":"","Labels":{}}
`)

	containers, err := runtime.ParseContainerLines(output)
	if err != nil {
		t.Fatalf("ParseContainerLines() error: %v", err)
	}

	byName := map[string]runtime.Container{}
	for _, container := range containers {
		byName[container.Name] = container
	}

	for _, name := range []string{"typing-app-backend", "typing-app-frontend", "typing-app-mongodb"} {
		container := byName[name]
		if container.ComposeProject != "typing-app" {
			t.Fatalf("%s: expected compose project typing-app, got %q", name, container.ComposeProject)
		}
	}

	if byName["typing-app-backend"].ComposeService != "backend" {
		t.Fatalf("expected compose service backend, got %q", byName["typing-app-backend"].ComposeService)
	}
}

func TestParseVolumeLines(t *testing.T) {
	output := []byte(`{"Driver":"local","Labels":"","Mountpoint":"/var/lib/nerdctl/volumes/default/toth_postgres_data/_data","Name":"toth_postgres_data","Scope":"local","Size":""}
{"Driver":"local","Labels":"","Mountpoint":"/var/lib/nerdctl/volumes/default/4ec7d441/_data","Name":"4ec7d441bc484b4b1bbcb1c9b55c7eee59313dfbfd2536a84ba58273c9d8132e","Scope":"local","Size":""}
`)

	volumes, err := runtime.ParseVolumeLines(output)
	if err != nil {
		t.Fatalf("ParseVolumeLines() error: %v", err)
	}

	if len(volumes) != 2 {
		t.Fatalf("expected 2 volumes, got %d", len(volumes))
	}

	if volumes[0].Name != "toth_postgres_data" {
		t.Fatalf("expected volume name toth_postgres_data, got %q", volumes[0].Name)
	}

	if volumes[0].Driver != "local" {
		t.Fatalf("expected driver local, got %q", volumes[0].Driver)
	}
}

func TestParseImageLines(t *testing.T) {
	output := []byte(`{"ID":"img1","Repository":"nginx","Tag":"latest","Size":"10MB","CreatedAt":"today"}
`)

	images, err := runtime.ParseImageLines(output)
	if err != nil {
		t.Fatalf("ParseImageLines() error: %v", err)
	}

	if len(images) != 1 {
		t.Fatalf("expected 1 image, got %d", len(images))
	}

	if images[0].Repository != "nginx" {
		t.Fatalf("expected repository nginx, got %q", images[0].Repository)
	}
}
