package runtime_test

import (
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestParseContainerLines(t *testing.T) {
	t.Helper()

	output := []byte(`{"ID":"abc","Names":"web","Image":"nginx","State":"running","Status":"Up","CreatedAt":"now"}
`)

	containers, err := runtime.ParseContainerLines(output)
	if err != nil {
		t.Fatalf("ParseContainerLines() error: %v", err)
	}

	if len(containers) != 1 {
		t.Fatalf("expected 1 container, got %d", len(containers))
	}

	if containers[0].Name != "web" {
		t.Fatalf("expected container name web, got %q", containers[0].Name)
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
