package buildhistory

import (
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestParseAttachmentRows(t *testing.T) {
	rows := parseAttachmentRows(`TYPE=application/vnd.oci.image.index.v1+json|PLATFORM=|DIGEST=sha256:abc
TYPE=https://slsa.dev/provenance/v0.2|PLATFORM=|DIGEST=sha256:def
TYPE=application/vnd.oci.image.manifest.v1+json|PLATFORM=linux/arm64|DIGEST=sha256:ghi`)

	if len(rows) != 3 {
		t.Fatalf("expected 3 rows, got %d", len(rows))
	}

	if rows[2].Platform != "linux/arm64" {
		t.Fatalf("unexpected platform: %q", rows[2].Platform)
	}
}

func TestOrderBuildArtifacts(t *testing.T) {
	ordered := orderBuildArtifacts([]runtime.BuildArtifact{
		{Name: "Provenance v1"},
		{Name: "OpenTelemetry traces"},
		{Name: "application/vnd.oci.image.config.v1+json"},
	})

	if len(ordered) != 3 {
		t.Fatalf("expected 3 artifacts, got %d", len(ordered))
	}

	if ordered[0].Name != "application/vnd.oci.image.config.v1+json" {
		t.Fatalf("unexpected first artifact: %q", ordered[0].Name)
	}
	if ordered[1].Name != "OpenTelemetry traces" {
		t.Fatalf("unexpected second artifact: %q", ordered[1].Name)
	}
	if ordered[2].Name != "Provenance v1" {
		t.Fatalf("unexpected third artifact: %q", ordered[2].Name)
	}
}
