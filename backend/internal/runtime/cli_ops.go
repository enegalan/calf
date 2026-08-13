package runtime

import (
	"context"
	"encoding/json"
	"fmt"
)

// cliOps holds the container/image/volume/network/registry operations that are identical
// between Native and Guest: a requireRunning/emptyIfStopped guard around a shared nerdctl.go
// (or similar) helper invoked through a runtime-specific command runner. Native and Guest embed
// cliOps and wire status/runLocal/runLocalWithStdin to their own methods in their constructors;
// operations whose behavior differs between the two runtimes (ListContainers, ListVolumeFiles,
// ApplyProxy, RunBuild, StreamLogs*, AttachExec, RegistryStatus, and the Start/Stop/ForceStop/
// Status/ResourceUsage lifecycle) stay defined on Native/Guest directly.
type cliOps struct {
	status            func(context.Context) (Status, error)
	runLocal          commandRunner
	runLocalWithStdin stdinCommandRunner
}

// ListImages returns all images, or none when the runtime is stopped.
func (o *cliOps) ListImages(ctx context.Context) ([]Image, error) {
	return emptyIfStopped(ctx, o.status, func(ctx context.Context) ([]Image, error) {
		return listImages(ctx, o.runLocal)
	})
}

// ImageHistory returns build layers for the given image reference.
func (o *cliOps) ImageHistory(ctx context.Context, ref string) ([]ImageLayer, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return nil, err
	}

	return imageHistory(ctx, o.runLocal, ref)
}

// ListVolumes returns all volumes with in-use enrichment, or none when stopped.
func (o *cliOps) ListVolumes(ctx context.Context) ([]Volume, error) {
	return emptyIfStopped(ctx, o.status, func(ctx context.Context) ([]Volume, error) {
		volumes, err := listVolumes(ctx, o.runLocal)
		if err != nil {
			return nil, err
		}

		return enrichVolumesInUse(ctx, o.runLocal, volumes)
	})
}

// ListNetworks returns all networks, or none when the runtime is stopped.
func (o *cliOps) ListNetworks(ctx context.Context) ([]Network, error) {
	return emptyIfStopped(ctx, o.status, func(ctx context.Context) ([]Network, error) {
		return listNetworks(ctx, o.runLocal)
	})
}

// InspectNetwork returns detailed metadata for a network by name.
func (o *cliOps) InspectNetwork(ctx context.Context, name string) (NetworkDetail, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return NetworkDetail{}, err
	}

	return inspectNetwork(ctx, o.runLocal, name)
}

// RemoveNetwork deletes a network by name.
func (o *cliOps) RemoveNetwork(ctx context.Context, name string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}

	return removeNetwork(ctx, o.runLocal, name)
}

// PrunePreview returns unused resources reclaimable by system prune.
func (o *cliOps) PrunePreview(ctx context.Context) (PrunePreview, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return PrunePreview{}, err
	}

	return prunePreview(ctx, o.runLocal)
}

// Prune removes unused resources for the selected categories.
func (o *cliOps) Prune(ctx context.Context, opts PruneOptions) (PruneResult, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return PruneResult{}, err
	}

	return prune(ctx, o.runLocal, opts)
}

// SystemDiskUsage returns Images/Containers/Volumes/Build Cache size from system df.
func (o *cliOps) SystemDiskUsage(ctx context.Context) (SystemDiskUsage, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return SystemDiskUsage{}, err
	}

	return systemDiskUsage(ctx, o.runLocal)
}

// CreateVolume creates a named volume, or an anonymous one when name is empty.
func (o *cliOps) CreateVolume(ctx context.Context, name string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}

	args := []string{"volume", "create"}
	if name != "" {
		args = append(args, name)
	}

	_, err := o.runLocal(ctx, "nerdctl", args...)
	return err
}

// CloneVolume copies data from source into a new dest volume.
func (o *cliOps) CloneVolume(ctx context.Context, source, dest string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}

	return cloneVolume(ctx, o.runLocal, source, dest)
}

// ExportVolume archives a volume to the destination described by opts.
func (o *cliOps) ExportVolume(ctx context.Context, opts VolumeExportOptions) (string, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return "", err
	}

	return RunVolumeExport(ctx, o.runLocal, opts)
}

// RemoveVolume deletes a volume by name.
func (o *cliOps) RemoveVolume(ctx context.Context, name string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}

	_, err := o.runLocal(ctx, "nerdctl", "volume", "rm", name)
	return err
}

// InspectVolume returns detailed metadata for a volume by name.
func (o *cliOps) InspectVolume(ctx context.Context, name string) (VolumeDetail, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return VolumeDetail{}, err
	}

	return inspectVolume(ctx, o.runLocal, name)
}

// VolumeContainers lists containers that mount the named volume.
func (o *cliOps) VolumeContainers(ctx context.Context, name string) ([]VolumeContainerUsage, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return nil, err
	}

	return volumeContainerUsages(ctx, o.runLocal, name)
}

// StartContainer starts a stopped container by ID.
func (o *cliOps) StartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}

	_, err := o.runLocal(ctx, "nerdctl", "start", id)
	return err
}

// StopContainer stops a running container by ID.
func (o *cliOps) StopContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}

	_, err := o.runLocal(ctx, "nerdctl", "stop", id)
	return err
}

// RemoveContainer force-removes a container by ID.
func (o *cliOps) RemoveContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}

	_, err := o.runLocal(ctx, "nerdctl", "rm", "-f", id)
	return err
}

// RemoveImage deletes an image by reference.
func (o *cliOps) RemoveImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}

	_, err := o.runLocal(ctx, "nerdctl", "rmi", ref)
	return err
}

// PullImage downloads an image from a registry.
func (o *cliOps) PullImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}

	_, err := o.runLocal(ctx, "nerdctl", "pull", ref)
	return err
}

// PushImage uploads an image to a registry.
func (o *cliOps) PushImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}

	return pushImage(ctx, o.runLocal, ref)
}

// RunImage starts a detached container from ref and returns its ID.
func (o *cliOps) RunImage(ctx context.Context, ref string) (string, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return "", err
	}

	return runImage(ctx, o.runLocal, ref)
}

// InspectContainer returns raw nerdctl inspect JSON for a container.
func (o *cliOps) InspectContainer(ctx context.Context, id string) (json.RawMessage, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return nil, err
	}

	return inspectContainer(ctx, o.runLocal, id)
}

// ContainerMounts parses mount points from container inspect data.
func (o *cliOps) ContainerMounts(ctx context.Context, id string) ([]ContainerMount, error) {
	inspect, err := o.InspectContainer(ctx, id)
	if err != nil {
		return nil, err
	}

	return parseContainerMounts(inspect)
}

// ListContainerFiles lists directory entries inside a container at path.
func (o *cliOps) ListContainerFiles(ctx context.Context, id, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return nil, err
	}

	if !isValidContainerPath(path) {
		return nil, fmt.Errorf("invalid path")
	}

	return listContainerFiles(ctx, o.runLocal, id, path)
}

// ExecContainer runs a one-shot command inside a container and returns stdout.
func (o *cliOps) ExecContainer(ctx context.Context, id, command string) (string, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return "", err
	}

	return execInContainer(ctx, o.runLocal, id, command)
}

// ContainerStats returns CPU and memory usage for a running container.
func (o *cliOps) ContainerStats(ctx context.Context, id string) (ContainerStats, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return ContainerStats{}, err
	}

	return containerStats(ctx, o.runLocal, id)
}

// RestartContainer stops and starts a container by ID.
func (o *cliOps) RestartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}

	return restartContainer(ctx, o.runLocal, id)
}

// RegistryLogin authenticates to a container registry with username and password.
func (o *cliOps) RegistryLogin(ctx context.Context, server, username, password string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}

	return registryLogin(ctx, o.runLocal, o.runLocalWithStdin, server, username, password)
}

// RegistryLogout removes stored credentials for a registry server.
func (o *cliOps) RegistryLogout(ctx context.Context, server string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}

	return registryLogout(ctx, o.runLocal, server)
}
