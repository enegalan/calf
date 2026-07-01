package runtime

import (
	"context"
	goruntime "runtime"
)

type Mode string

const (
	ModeVM     Mode = "vm"
	ModeNative Mode = "native"
)

type State string

const (
	StateRunning State = "running"
	StateStopped State = "stopped"
	StateUnknown State = "unknown"
)

type Status struct {
	Mode         Mode   `json:"mode"`
	State        State  `json:"state"`
	DockerSocket string `json:"docker_socket"`
	VMName       string `json:"vm_name,omitempty"`
}

type Container struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Image   string `json:"image"`
	State   string `json:"state"`
	Status  string `json:"status"`
	Created string `json:"created"`
}

type Image struct {
	ID         string `json:"id"`
	Repository string `json:"repository"`
	Tag        string `json:"tag"`
	Size       string `json:"size"`
	Created    string `json:"created"`
}

type Runtime interface {
	Start(ctx context.Context) error
	Stop(ctx context.Context) error
	Status(ctx context.Context) (Status, error)
	DockerSocket() string
	ListContainers(ctx context.Context) ([]Container, error)
	ListImages(ctx context.Context) ([]Image, error)
	StartContainer(ctx context.Context, id string) error
	StopContainer(ctx context.Context, id string) error
	RemoveContainer(ctx context.Context, id string) error
	RemoveImage(ctx context.Context, ref string) error
	PullImage(ctx context.Context, ref string) error
	StreamLogs(ctx context.Context, id string, output func(string)) error
}

func New(vmName string, dockerSocket string) Runtime {
	if goruntime.GOOS == "linux" {
		return NewNative(vmName, dockerSocket)
	}

	return NewLima(vmName, dockerSocket)
}
