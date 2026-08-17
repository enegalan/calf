package runtime_test

import (
	"strings"
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestExtraFileShareSpecsSkipsHome(t *testing.T) {
	specs := runtime.ExtraFileShareSpecs("/Users/me", []string{
		"/Users/me/src",
		"/tmp",
		"/tmp",
		"/Volumes/Work",
		"relative",
		"",
	})
	if len(specs) != 2 {
		t.Fatalf("got %d specs, want 2: %+v", len(specs), specs)
	}
	if specs[0].HostPath != "/tmp" || specs[0].Tag != "calf-share-0" {
		t.Fatalf("first spec: %+v", specs[0])
	}
	if specs[1].HostPath != "/Volumes/Work" {
		t.Fatalf("second spec: %+v", specs[1])
	}
}

func TestMergeDaemonJSONOverlayAndSubnet(t *testing.T) {
	merged, err := runtime.MergeDaemonJSON(`{"debug": true}`, "192.168.215.1/24")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(merged, `"buildkit"`) {
		t.Fatalf("missing baked buildkit: %s", merged)
	}
	if !strings.Contains(merged, `"debug": true`) {
		t.Fatalf("missing overlay debug: %s", merged)
	}
	if !strings.Contains(merged, `"bip": "192.168.215.1/24"`) {
		t.Fatalf("missing subnet: %s", merged)
	}
}

func TestMergeDaemonJSONInvalid(t *testing.T) {
	if _, err := runtime.MergeDaemonJSON("{", ""); err == nil {
		t.Fatal("expected invalid JSON error")
	}
}
