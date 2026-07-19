package runtime

import (
	"context"
	"encoding/json"
	"io"
	goruntime "runtime"
)

// Mode represents the mode of the runtime.
type Mode string

// State represents the state of the runtime.
type State string

// PortConflict represents a port conflict.
type PortConflict struct {
	Port    int    `json:"port"`
	Process string `json:"process"`
	Hint    string `json:"hint"`
}

// Status represents the status of the runtime.
type Status struct {
	Mode          Mode           `json:"mode"`
	State         State          `json:"state"`
	DockerSocket  string         `json:"docker_socket"`
	Rootless      bool           `json:"rootless"`
	VMName        string         `json:"vm_name,omitempty"`
	PortConflicts []PortConflict `json:"port_conflicts,omitempty"`
	Log           string         `json:"log,omitempty"`
}

// Container represents a container.
type Container struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Image          string `json:"image"`
	State          string `json:"state"`
	Status         string `json:"status"`
	Ports          string `json:"ports"`
	Created        string `json:"created"`
	ComposeProject string `json:"compose_project"`
	ComposeService string `json:"compose_service"`
}

// Image represents an image.
type Image struct {
	ID         string `json:"id"`
	Repository string `json:"repository"`
	Tag        string `json:"tag"`
	Size       string `json:"size"`
	Created    string `json:"created"`
}

// ImageLayer represents a layer of an image.
type ImageLayer struct {
	Index     int    `json:"index"`
	CreatedBy string `json:"created_by"`
	Size      string `json:"size"`
	Created   string `json:"created,omitempty"`
}

// Volume represents a volume.
type Volume struct {
	Name    string `json:"name"`
	Driver  string `json:"driver"`
	InUse   bool   `json:"in_use"`
	Size    string `json:"size"`
	Created string `json:"created"`
}

// VolumeDetail represents the details of a volume.
type VolumeDetail struct {
	Name       string `json:"name"`
	Driver     string `json:"driver"`
	Created    string `json:"created"`
	InUse      bool   `json:"in_use"`
	Mountpoint string `json:"mountpoint,omitempty"`
}

// VolumeContainerUsage represents the usage of a volume by a container.
type VolumeContainerUsage struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Image  string `json:"image"`
	Port   string `json:"port"`
	Target string `json:"target"`
}

// Network represents a network.
type Network struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Driver  string `json:"driver"`
	Scope   string `json:"scope"`
	Subnet  string `json:"subnet"`
	Created string `json:"created"`
}

// NetworkDetail represents the details of a network.
type NetworkDetail struct {
	ID      string            `json:"id"`
	Name    string            `json:"name"`
	Driver  string            `json:"driver"`
	Scope   string            `json:"scope"`
	Subnet  string            `json:"subnet"`
	Gateway string            `json:"gateway"`
	Created string            `json:"created"`
	Options map[string]string `json:"options"`
}

// Runtime represents a runtime.
type Runtime interface {
	Start(ctx context.Context) error
	Stop(ctx context.Context) error
	Status(ctx context.Context) (Status, error)
	DockerSocket() string
	ListContainers(ctx context.Context) ([]Container, error)
	ListImages(ctx context.Context) ([]Image, error)
	ImageHistory(ctx context.Context, ref string) ([]ImageLayer, error)
	ListVolumes(ctx context.Context) ([]Volume, error)
	InspectVolume(ctx context.Context, name string) (VolumeDetail, error)
	ListVolumeFiles(ctx context.Context, name, path string) ([]ContainerFileEntry, error)
	VolumeContainers(ctx context.Context, name string) ([]VolumeContainerUsage, error)
	StartContainer(ctx context.Context, id string) error
	StopContainer(ctx context.Context, id string) error
	RemoveContainer(ctx context.Context, id string) error
	RemoveImage(ctx context.Context, ref string) error
	PullImage(ctx context.Context, ref string) error
	PushImage(ctx context.Context, ref string) error
	RunImage(ctx context.Context, ref string) (string, error)
	CreateVolume(ctx context.Context, name string) error
	CloneVolume(ctx context.Context, source, dest string) error
	ExportVolume(ctx context.Context, opts VolumeExportOptions) (string, error)
	RemoveVolume(ctx context.Context, name string) error
	RunBuild(ctx context.Context, contextPath, tag, dockerfile, platform string) (BuildResult, error)
	StreamLogs(ctx context.Context, id string, output func(string)) error
	StreamLogsFollow(ctx context.Context, id string, output func(string)) error
	InspectContainer(ctx context.Context, id string) (json.RawMessage, error)
	ContainerMounts(ctx context.Context, id string) ([]ContainerMount, error)
	ListContainerFiles(ctx context.Context, id, path string) ([]ContainerFileEntry, error)
	ExecContainer(ctx context.Context, id, command string) (string, error)
	AttachExec(ctx context.Context, id string, stdin io.Reader, onOutput func([]byte), resizeCh <-chan ExecResize) error
	ContainerStats(ctx context.Context, id string) (ContainerStats, error)
	RestartContainer(ctx context.Context, id string) error
	RegistryStatus(ctx context.Context) (RegistryStatus, error)
	RegistryLogin(ctx context.Context, server, username, password string) error
	RegistryLogout(ctx context.Context, server string) error
	ListNetworks(ctx context.Context) ([]Network, error)
	InspectNetwork(ctx context.Context, name string) (NetworkDetail, error)
	RemoveNetwork(ctx context.Context, name string) error
	ApplyProxy(ctx context.Context, proxy ProxyConfig) error
}

// New returns the platform-appropriate Runtime implementation.
func New(vmName string, dockerSocket string, cpus int, memoryGB int, memorySwapGB int, diskGB int, apiListenPort int, vmKeepAlive bool, rootless bool, proxy ProxyConfig) Runtime {
	if goruntime.GOOS == "linux" {
		return NewNative(vmName, dockerSocket, cpus, memoryGB, memorySwapGB, diskGB, rootless, proxy)
	}

	if goruntime.GOOS == "darwin" {
		return newDarwinRuntime(vmName, dockerSocket, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort, vmKeepAlive, proxy)
	}

	return NewLima(vmName, dockerSocket, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort, vmKeepAlive, proxy)
}
