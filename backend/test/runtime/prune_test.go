package runtime_test

import (
	"context"
	"testing"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestMockPrunePreviewAndPrune(t *testing.T) {
	mock := runtime.NewMock()
	mock.Containers = append(mock.Containers, runtime.Container{
		ID:    "dead01",
		Name:  "old",
		Image: "hello-world",
		State: "exited",
	})
	mock.Images = append(mock.Images, runtime.Image{
		ID:         "img999",
		Repository: "alpine",
		Tag:        "3.20",
		Size:       "5MB",
	})
	mock.Volumes = append(mock.Volumes, runtime.Volume{
		Name:   "orphan-vol",
		Driver: "local",
		Size:   "1MB",
	})
	mock.Networks = append(mock.Networks, runtime.Network{
		ID:     "net123",
		Name:   "app_net",
		Driver: "bridge",
	})
	mock.SetBuildCacheBytes(2_000_000)

	preview, err := mock.PrunePreview(context.Background())
	if err != nil {
		t.Fatalf("PrunePreview() error: %v", err)
	}
	if len(preview.Containers.Items) != 1 || preview.Containers.Items[0].Name != "old" {
		t.Fatalf("expected one stopped container, got %+v", preview.Containers.Items)
	}
	if len(preview.Images.Items) != 1 || preview.Images.Items[0].ID != "img999" {
		t.Fatalf("expected unused alpine image, got %+v", preview.Images.Items)
	}
	// With a running container, default mock volumes stay in use; orphan still unused only when no containers — with running hello, InUse=true for all in mock list enrichment.
	// Mock PrunePreview sets InUse = len(containers) > 0 for every volume, so volumes preview is empty while any container exists.
	if len(preview.Networks.Items) != 1 || preview.Networks.Items[0].Name != "app_net" {
		t.Fatalf("expected app_net candidate, got %+v", preview.Networks.Items)
	}
	if preview.BuildCache.ReclaimableBytes != 2_000_000 {
		t.Fatalf("expected build cache bytes, got %d", preview.BuildCache.ReclaimableBytes)
	}

	result, err := mock.Prune(context.Background(), runtime.PruneOptions{
		Containers: true,
		Images:     true,
		Networks:   true,
		BuildCache: true,
	})
	if err != nil {
		t.Fatalf("Prune() error: %v", err)
	}
	if !result.Containers || !result.Images || !result.Networks || !result.BuildCache {
		t.Fatalf("expected selected categories pruned, got %+v", result)
	}

	previewAfter, err := mock.PrunePreview(context.Background())
	if err != nil {
		t.Fatalf("PrunePreview() after prune error: %v", err)
	}
	if len(previewAfter.Containers.Items) != 0 {
		t.Fatalf("expected no stopped containers after prune, got %+v", previewAfter.Containers.Items)
	}
	if len(previewAfter.Images.Items) != 0 {
		t.Fatalf("expected no unused images after prune, got %+v", previewAfter.Images.Items)
	}
	if len(previewAfter.Networks.Items) != 0 {
		t.Fatalf("expected no custom networks after prune, got %+v", previewAfter.Networks.Items)
	}
	if previewAfter.BuildCache.ReclaimableBytes != 0 {
		t.Fatalf("expected empty build cache after prune, got %d", previewAfter.BuildCache.ReclaimableBytes)
	}
}

func TestMockPruneRequiresCategory(t *testing.T) {
	mock := runtime.NewMock()
	_, err := mock.Prune(context.Background(), runtime.PruneOptions{})
	if err == nil {
		t.Fatal("expected error when no category selected")
	}
}

func TestMockPrunePreviewRequiresRunning(t *testing.T) {
	mock := runtime.NewMock()
	mock.StatusValue.State = runtime.State(constants.RuntimeStateStopped)
	_, err := mock.PrunePreview(context.Background())
	if err != runtime.ErrRuntimeNotRunning {
		t.Fatalf("expected ErrRuntimeNotRunning, got %v", err)
	}
}
