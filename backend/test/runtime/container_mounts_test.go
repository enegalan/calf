package runtime_test

import (
	"context"
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestContainerMountsDedupesMountsAndHostConfigBinds(t *testing.T) {
	mock := runtime.NewMock()

	mounts, err := mock.ContainerMounts(context.Background(), "abc123")
	if err != nil {
		t.Fatalf("ContainerMounts() error: %v", err)
	}

	if len(mounts) != 1 {
		t.Fatalf("expected 1 mount after dedupe, got %d: %+v", len(mounts), mounts)
	}

	if mounts[0].Source != "/host/data" || mounts[0].Destination != "/data" {
		t.Fatalf("unexpected mount: %+v", mounts[0])
	}

	if mounts[0].Type != "bind" {
		t.Fatalf("expected bind type, got %q", mounts[0].Type)
	}
}
