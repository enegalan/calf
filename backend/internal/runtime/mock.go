package runtime

import (
	"context"
	"sync"
)

type Mock struct {
	mu sync.Mutex

	StatusValue    Status
	Containers     []Container
	Images         []Image
	StartErr       error
	StopErr        error
	StatusErr      error
	ContainersErr  error
	ImagesErr      error
	ContainerErr   error
	ImageErr       error
	LogLines       []string
	Started        bool
}

func NewMock() *Mock {
	return &Mock{
		StatusValue: Status{
			Mode:         ModeVM,
			State:        StateRunning,
			DockerSocket: "/tmp/calf-test.sock",
			VMName:       "calf",
		},
		Containers: []Container{
			{
				ID:     "abc123",
				Name:   "hello",
				Image:  "hello-world",
				State:  "running",
				Status: "Up 1 minute",
			},
		},
		Images: []Image{
			{
				ID:         "def456",
				Repository: "hello-world",
				Tag:        "latest",
				Size:       "10MB",
			},
		},
		LogLines: []string{"hello", "world"},
	}
}

func (m *Mock) DockerSocket() string {
	return m.StatusValue.DockerSocket
}

func (m *Mock) Start(_ context.Context) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.StartErr != nil {
		return m.StartErr
	}

	m.Started = true
	m.StatusValue.State = StateRunning
	return nil
}

func (m *Mock) Stop(_ context.Context) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.StopErr != nil {
		return m.StopErr
	}

	m.Started = false
	m.StatusValue.State = StateStopped
	return nil
}

func (m *Mock) Status(_ context.Context) (Status, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.StatusErr != nil {
		return Status{}, m.StatusErr
	}

	return m.StatusValue, nil
}

func (m *Mock) ListContainers(_ context.Context) ([]Container, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.ContainersErr != nil {
		return nil, m.ContainersErr
	}

	return append([]Container(nil), m.Containers...), nil
}

func (m *Mock) ListImages(_ context.Context) ([]Image, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.ImagesErr != nil {
		return nil, m.ImagesErr
	}

	return append([]Image(nil), m.Images...), nil
}

func (m *Mock) StartContainer(_ context.Context, id string) error {
	if m.ContainerErr != nil {
		return m.ContainerErr
	}

	for index, container := range m.Containers {
		if container.ID == id {
			m.Containers[index].State = "running"
			m.Containers[index].Status = "Up"
		}
	}

	return nil
}

func (m *Mock) StopContainer(_ context.Context, id string) error {
	if m.ContainerErr != nil {
		return m.ContainerErr
	}

	for index, container := range m.Containers {
		if container.ID == id {
			m.Containers[index].State = "exited"
			m.Containers[index].Status = "Exited"
		}
	}

	return nil
}

func (m *Mock) RemoveContainer(_ context.Context, id string) error {
	if m.ContainerErr != nil {
		return m.ContainerErr
	}

	filtered := make([]Container, 0, len(m.Containers))
	for _, container := range m.Containers {
		if container.ID != id {
			filtered = append(filtered, container)
		}
	}

	m.Containers = filtered
	return nil
}

func (m *Mock) RemoveImage(_ context.Context, ref string) error {
	if m.ImageErr != nil {
		return m.ImageErr
	}

	filtered := make([]Image, 0, len(m.Images))
	for _, image := range m.Images {
		if image.Repository+":"+image.Tag != ref && image.ID != ref {
			filtered = append(filtered, image)
		}
	}

	m.Images = filtered
	return nil
}

func (m *Mock) PullImage(_ context.Context, ref string) error {
	if m.ImageErr != nil {
		return m.ImageErr
	}

	m.Images = append(m.Images, Image{
		ID:         "pulled",
		Repository: ref,
		Tag:        "latest",
		Size:       "1MB",
	})

	return nil
}

func (m *Mock) StreamLogs(_ context.Context, _ string, output func(string)) error {
	for _, line := range m.LogLines {
		output(line)
	}

	return nil
}
