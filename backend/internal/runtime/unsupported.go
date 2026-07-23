package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/enegalan/calf/backend/internal/constants"
)

// Unsupported is a Runtime that refuses all engine operations with a fixed reason.
// Used on Windows until a non-Lima VM backend exists.
type Unsupported struct {
	dockerSocket string
	reason       string
}

// NewUnsupported returns a Runtime that surfaces reason for every engine call.
func NewUnsupported(dockerSocket, reason string) *Unsupported {
	if reason == "" {
		reason = "container engine is not available on this platform"
	}
	return &Unsupported{dockerSocket: dockerSocket, reason: reason}
}

// NewWindowsUnsupported returns the Windows stub runtime (Lima removed; no replacement yet).
func NewWindowsUnsupported(dockerSocket string) *Unsupported {
	return NewUnsupported(dockerSocket,
		"Windows container engine is not available in this release (Lima was removed); use macOS or Linux")
}

func (u *Unsupported) err() error { return fmt.Errorf("%s", u.reason) }

// DockerSocket returns the configured socket path (unused while unsupported).
func (u *Unsupported) DockerSocket() string { return u.dockerSocket }

// Start refuses to start a container engine on this platform.
func (u *Unsupported) Start(context.Context) error { return u.err() }

// Stop is a no-op for the unsupported runtime.
func (u *Unsupported) Stop(context.Context) error { return nil }

// ForceStop is a no-op for the unsupported runtime.
func (u *Unsupported) ForceStop(context.Context) error { return nil }

// ResourceUsage returns zeros for the unsupported runtime.
func (u *Unsupported) ResourceUsage(context.Context) (ResourceUsage, error) {
	return ResourceUsage{}, nil
}

// Status reports a stopped engine with the unsupported reason in Log.
func (u *Unsupported) Status(context.Context) (Status, error) {
	return Status{
		Mode:         Mode(constants.RuntimeModeVM),
		State:        State(constants.RuntimeStateStopped),
		DockerSocket: u.dockerSocket,
		Log:          u.reason,
	}, nil
}

// ListContainers returns an error because the engine is unsupported.
func (u *Unsupported) ListContainers(context.Context) ([]Container, error) {
	return nil, u.err()
}

// ListImages returns an error because the engine is unsupported.
func (u *Unsupported) ListImages(context.Context) ([]Image, error) { return nil, u.err() }

// ImageHistory returns an error because the engine is unsupported.
func (u *Unsupported) ImageHistory(context.Context, string) ([]ImageLayer, error) {
	return nil, u.err()
}

// ListVolumes returns an error because the engine is unsupported.
func (u *Unsupported) ListVolumes(context.Context) ([]Volume, error) { return nil, u.err() }

// InspectVolume returns an error because the engine is unsupported.
func (u *Unsupported) InspectVolume(context.Context, string) (VolumeDetail, error) {
	return VolumeDetail{}, u.err()
}

// ListVolumeFiles returns an error because the engine is unsupported.
func (u *Unsupported) ListVolumeFiles(context.Context, string, string) ([]ContainerFileEntry, error) {
	return nil, u.err()
}

// VolumeContainers returns an error because the engine is unsupported.
func (u *Unsupported) VolumeContainers(context.Context, string) ([]VolumeContainerUsage, error) {
	return nil, u.err()
}

// StartContainer returns an error because the engine is unsupported.
func (u *Unsupported) StartContainer(context.Context, string) error { return u.err() }

// StopContainer returns an error because the engine is unsupported.
func (u *Unsupported) StopContainer(context.Context, string) error { return u.err() }

// RemoveContainer returns an error because the engine is unsupported.
func (u *Unsupported) RemoveContainer(context.Context, string) error { return u.err() }

// RemoveImage returns an error because the engine is unsupported.
func (u *Unsupported) RemoveImage(context.Context, string) error { return u.err() }

// PullImage returns an error because the engine is unsupported.
func (u *Unsupported) PullImage(context.Context, string) error { return u.err() }

// PushImage returns an error because the engine is unsupported.
func (u *Unsupported) PushImage(context.Context, string) error { return u.err() }

// RunImage returns an error because the engine is unsupported.
func (u *Unsupported) RunImage(context.Context, string) (string, error) { return "", u.err() }

// CreateVolume returns an error because the engine is unsupported.
func (u *Unsupported) CreateVolume(context.Context, string) error { return u.err() }

// CloneVolume returns an error because the engine is unsupported.
func (u *Unsupported) CloneVolume(context.Context, string, string) error { return u.err() }

// ExportVolume returns an error because the engine is unsupported.
func (u *Unsupported) ExportVolume(context.Context, VolumeExportOptions) (string, error) {
	return "", u.err()
}

// RemoveVolume returns an error because the engine is unsupported.
func (u *Unsupported) RemoveVolume(context.Context, string) error { return u.err() }

// RunBuild returns an error because the engine is unsupported.
func (u *Unsupported) RunBuild(context.Context, string, string, string, string) (BuildResult, error) {
	return BuildResult{}, u.err()
}

// StreamLogs returns an error because the engine is unsupported.
func (u *Unsupported) StreamLogs(context.Context, string, func(string)) error { return u.err() }

// StreamLogsFollow returns an error because the engine is unsupported.
func (u *Unsupported) StreamLogsFollow(context.Context, string, func(string)) error {
	return u.err()
}

// InspectContainer returns an error because the engine is unsupported.
func (u *Unsupported) InspectContainer(context.Context, string) (json.RawMessage, error) {
	return nil, u.err()
}

// ContainerMounts returns an error because the engine is unsupported.
func (u *Unsupported) ContainerMounts(context.Context, string) ([]ContainerMount, error) {
	return nil, u.err()
}

// ListContainerFiles returns an error because the engine is unsupported.
func (u *Unsupported) ListContainerFiles(context.Context, string, string) ([]ContainerFileEntry, error) {
	return nil, u.err()
}

// ExecContainer returns an error because the engine is unsupported.
func (u *Unsupported) ExecContainer(context.Context, string, string) (string, error) {
	return "", u.err()
}

// AttachExec returns an error because the engine is unsupported.
func (u *Unsupported) AttachExec(context.Context, string, io.Reader, func([]byte), <-chan ExecResize) error {
	return u.err()
}

// ContainerStats returns an error because the engine is unsupported.
func (u *Unsupported) ContainerStats(context.Context, string) (ContainerStats, error) {
	return ContainerStats{}, u.err()
}

// RestartContainer returns an error because the engine is unsupported.
func (u *Unsupported) RestartContainer(context.Context, string) error { return u.err() }

// RegistryStatus returns an error because the engine is unsupported.
func (u *Unsupported) RegistryStatus(context.Context) (RegistryStatus, error) {
	return RegistryStatus{}, u.err()
}

// RegistryLogin returns an error because the engine is unsupported.
func (u *Unsupported) RegistryLogin(context.Context, string, string, string) error {
	return u.err()
}

// RegistryLogout returns an error because the engine is unsupported.
func (u *Unsupported) RegistryLogout(context.Context, string) error { return u.err() }

// ListNetworks returns an error because the engine is unsupported.
func (u *Unsupported) ListNetworks(context.Context) ([]Network, error) { return nil, u.err() }

// InspectNetwork returns an error because the engine is unsupported.
func (u *Unsupported) InspectNetwork(context.Context, string) (NetworkDetail, error) {
	return NetworkDetail{}, u.err()
}

// RemoveNetwork returns an error because the engine is unsupported.
func (u *Unsupported) RemoveNetwork(context.Context, string) error { return u.err() }

// ApplyProxy returns an error because the engine is unsupported.
func (u *Unsupported) ApplyProxy(context.Context, ProxyConfig) error { return u.err() }
