package runtime_test

import (
	"strings"
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestCollectEmptyNameContainerIDs(t *testing.T) {
	output := "4c256c6b121a\t\n" +
		"40791a3370f7\tiso-b\n" +
		"65a2596f9b69\t\n" +
		"not-an-id\t\n" +
		"abc\t\n"

	ids := runtime.CollectEmptyNameContainerIDs(output)
	if len(ids) != 2 {
		t.Fatalf("expected 2 corrupt ids, got %v", ids)
	}
	if ids[0] != "4c256c6b121a" || ids[1] != "65a2596f9b69" {
		t.Fatalf("unexpected ids: %v", ids)
	}
}

func TestCorruptContainerWipeScript(t *testing.T) {
	script := runtime.CorruptContainerWipeScript([]string{"4c256c6b121a", "bad id", "65a2596f9b69"})
	if !strings.Contains(script, "rm -rf /var/lib/docker/containers/4c256c6b121a") {
		t.Fatalf("missing wipe for 4c256c6b121a: %s", script)
	}
	if !strings.Contains(script, "rm -rf /var/lib/docker/containers/65a2596f9b69") {
		t.Fatalf("missing wipe for 65a2596f9b69: %s", script)
	}
	if strings.Contains(script, "bad id") {
		t.Fatalf("unsafe id interpolated into script: %s", script)
	}
	if !strings.Contains(script, "systemctl try-restart containerd.service docker.service") {
		t.Fatalf("missing deferred docker restart: %s", script)
	}
}
