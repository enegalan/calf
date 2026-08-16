package daemon

import (
	"context"
	"sync"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// resourceSnapshot holds the last resource lists served while the engine was running.
// Resource Saver returns this snapshot so lists stay visible without waking the VM.
type resourceSnapshot struct {
	mu         sync.RWMutex
	containers []runtime.Container
	images     []runtime.Image
	volumes    []runtime.Volume
	networks   []runtime.Network
}

// ListContainers returns live containers when the engine is running, or the
// Resource Saver snapshot while the engine is idle-stopped.
func (s *Core) ListContainers(ctx context.Context) ([]runtime.Container, error) {
	return listSnapshot(s, ctx, s.Runtime.ListContainers, s.snapshot.copyContainers, s.snapshot.replaceContainers)
}

// ListImages returns live images when the engine is running, or the Resource Saver snapshot.
func (s *Core) ListImages(ctx context.Context) ([]runtime.Image, error) {
	return listSnapshot(s, ctx, s.Runtime.ListImages, s.snapshot.copyImages, s.snapshot.replaceImages)
}

// ListVolumes returns live volumes when the engine is running, or the Resource Saver snapshot.
func (s *Core) ListVolumes(ctx context.Context) ([]runtime.Volume, error) {
	return listSnapshot(s, ctx, s.Runtime.ListVolumes, s.snapshot.copyVolumes, s.snapshot.replaceVolumes)
}

// ListNetworks returns live networks when the engine is running, or the Resource Saver snapshot.
func (s *Core) ListNetworks(ctx context.Context) ([]runtime.Network, error) {
	return listSnapshot(s, ctx, s.Runtime.ListNetworks, s.snapshot.copyNetworks, s.snapshot.replaceNetworks)
}

// EnterResourceSaver snapshots current lists and force-stops the engine.
func (s *Core) EnterResourceSaver(ctx context.Context) error {
	s.captureResourceSnapshot(ctx)
	if s.resourceSaver != nil {
		s.resourceSaver.markActive()
	}
	if err := s.ForceStopRuntime(ctx); err != nil {
		s.ClearResourceSaver()
		return err
	}
	return nil
}

// captureResourceSnapshot stores live lists before the engine is stopped.
func (s *Core) captureResourceSnapshot(ctx context.Context) {
	containers, containersErr := s.Runtime.ListContainers(ctx)
	if containersErr != nil {
		s.Logger.Debug("resource saver snapshot containers failed", "error", containersErr)
	} else {
		s.snapshot.replaceContainers(containers)
	}

	images, imagesErr := s.Runtime.ListImages(ctx)
	if imagesErr != nil {
		s.Logger.Debug("resource saver snapshot images failed", "error", imagesErr)
	} else {
		s.snapshot.replaceImages(images)
	}

	volumes, volumesErr := s.Runtime.ListVolumes(ctx)
	if volumesErr != nil {
		s.Logger.Debug("resource saver snapshot volumes failed", "error", volumesErr)
	} else {
		s.snapshot.replaceVolumes(volumes)
	}

	networks, networksErr := s.Runtime.ListNetworks(ctx)
	if networksErr != nil {
		s.Logger.Debug("resource saver snapshot networks failed", "error", networksErr)
	} else {
		s.snapshot.replaceNetworks(networks)
	}
}

// clearResourceSnapshot drops cached lists after purge or factory reset.
func (s *Core) clearResourceSnapshot() {
	s.snapshot.replaceContainers(nil)
	s.snapshot.replaceImages(nil)
	s.snapshot.replaceVolumes(nil)
	s.snapshot.replaceNetworks(nil)
}

// serveResourceSnapshot reports whether list APIs should return the idle snapshot.
func (s *Core) serveResourceSnapshot(ctx context.Context) bool {
	if !s.ResourceSaverActive() {
		return false
	}
	status, err := s.Runtime.Status(ctx)
	if err != nil {
		return true
	}
	return status.State != runtime.State(constants.RuntimeStateRunning)
}

// listSnapshot returns the live list while running, or the snapshot in Resource Saver.
func listSnapshot[T any](
	s *Core,
	ctx context.Context,
	live func(context.Context) ([]T, error),
	get func() []T,
	set func([]T),
) ([]T, error) {
	if s.serveResourceSnapshot(ctx) {
		return get(), nil
	}
	items, err := live(ctx)
	if err != nil {
		return nil, err
	}
	set(items)
	return items, nil
}

// copyContainers returns a copy of the cached container list.
func (s *resourceSnapshot) copyContainers() []runtime.Container {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]runtime.Container(nil), s.containers...)
}

// replaceContainers stores a copy of containers as the current snapshot.
func (s *resourceSnapshot) replaceContainers(items []runtime.Container) {
	s.mu.Lock()
	s.containers = append([]runtime.Container(nil), items...)
	s.mu.Unlock()
}

// copyImages returns a copy of the cached image list.
func (s *resourceSnapshot) copyImages() []runtime.Image {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]runtime.Image(nil), s.images...)
}

// replaceImages stores a copy of images as the current snapshot.
func (s *resourceSnapshot) replaceImages(items []runtime.Image) {
	s.mu.Lock()
	s.images = append([]runtime.Image(nil), items...)
	s.mu.Unlock()
}

// copyVolumes returns a copy of the cached volume list.
func (s *resourceSnapshot) copyVolumes() []runtime.Volume {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]runtime.Volume(nil), s.volumes...)
}

// replaceVolumes stores a copy of volumes as the current snapshot.
func (s *resourceSnapshot) replaceVolumes(items []runtime.Volume) {
	s.mu.Lock()
	s.volumes = append([]runtime.Volume(nil), items...)
	s.mu.Unlock()
}

// copyNetworks returns a copy of the cached network list.
func (s *resourceSnapshot) copyNetworks() []runtime.Network {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]runtime.Network(nil), s.networks...)
}

// replaceNetworks stores a copy of networks as the current snapshot.
func (s *resourceSnapshot) replaceNetworks(items []runtime.Network) {
	s.mu.Lock()
	s.networks = append([]runtime.Network(nil), items...)
	s.mu.Unlock()
}
