package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"sync"
)

type Mock struct {
	mu sync.Mutex

	StatusValue    Status
	Containers     []Container
	Images         []Image
	Volumes        []Volume
	StartErr       error
	StopErr        error
	StatusErr      error
	ContainersErr  error
	ImagesErr      error
	ContainerErr   error
	ExportVolumeErr error
	ImageErr       error
	LogLines       []string
	Started        bool
	registryLoggedIn bool
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
		Volumes: []Volume{
			{Name: "calf-data", Driver: "local"},
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

func (m *Mock) ImageHistory(_ context.Context, ref string) ([]ImageLayer, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.ImagesErr != nil {
		return nil, m.ImagesErr
	}

	if m.StatusValue.State != StateRunning {
		return nil, ErrRuntimeNotRunning
	}

	_ = ref
	return []ImageLayer{
		{Index: 0, CreatedBy: "# debian.sh --arch 'arm64'", Size: "104.3 MiB", Created: "6 months ago"},
		{Index: 1, CreatedBy: "RUN apt-get update && apt-get install -y coturn", Size: "31.7 MiB", Created: "5 months ago"},
		{Index: 2, CreatedBy: "CMD [\"--log-file=stdout\"]", Size: "0 B", Created: "5 months ago"},
	}, nil
}

func (m *Mock) ListVolumes(_ context.Context) ([]Volume, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.StatusValue.State != StateRunning {
		return []Volume{}, nil
	}

	volumes := append([]Volume(nil), m.Volumes...)
	for index := range volumes {
		volumes[index].InUse = len(m.Containers) > 0
		volumes[index].Size = "88 B"
		volumes[index].Created = "9 months ago"
	}

	return volumes, nil
}

func (m *Mock) CreateVolume(_ context.Context, name string) error {
	if m.ContainerErr != nil {
		return m.ContainerErr
	}

	m.Volumes = append(m.Volumes, Volume{Name: name, Driver: "local"})
	return nil
}

func (m *Mock) CloneVolume(_ context.Context, source, dest string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.ContainerErr != nil {
		return m.ContainerErr
	}

	found := false
	driver := "local"
	for _, volume := range m.Volumes {
		if volume.Name == source {
			found = true
			driver = volume.Driver
			break
		}
	}

	if !found {
		return fmt.Errorf("volume %s not found", source)
	}

	for _, volume := range m.Volumes {
		if volume.Name == dest {
			return fmt.Errorf("volume %s already exists", dest)
		}
	}

	m.Volumes = append(m.Volumes, Volume{Name: dest, Driver: driver})
	return nil
}

func (m *Mock) ExportVolume(_ context.Context, opts VolumeExportOptions) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.ExportVolumeErr != nil {
		return "", m.ExportVolumeErr
	}

	switch opts.Type {
	case "local_file":
		if opts.Folder == "" {
			return "", fmt.Errorf("destination folder is required")
		}

		return filepath.Join(opts.Folder, opts.FileName), nil
	case "local_image", "new_image", "registry":
		if opts.ImageRef == "" {
			return "", fmt.Errorf("image reference is required")
		}

		return opts.ImageRef, nil
	default:
		return "", fmt.Errorf("unsupported export type %q", opts.Type)
	}
}

func (m *Mock) RemoveVolume(_ context.Context, name string) error {
	if m.ContainerErr != nil {
		return m.ContainerErr
	}

	filtered := make([]Volume, 0, len(m.Volumes))
	for _, volume := range m.Volumes {
		if volume.Name != name {
			filtered = append(filtered, volume)
		}
	}

	m.Volumes = filtered
	return nil
}

func (m *Mock) InspectVolume(_ context.Context, name string) (VolumeDetail, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.StatusValue.State != StateRunning {
		return VolumeDetail{}, ErrRuntimeNotRunning
	}

	for _, volume := range m.Volumes {
		if volume.Name != name {
			continue
		}

		return VolumeDetail{
			Name:       volume.Name,
			Driver:     volume.Driver,
			Created:    "9 months ago",
			InUse:      len(m.Containers) > 0,
			Mountpoint: "/var/lib/mock/volumes/" + volume.Name + "/_data",
		}, nil
	}

	return VolumeDetail{}, fmt.Errorf("volume %s not found", name)
}

func (m *Mock) ListVolumeFiles(_ context.Context, name, path string) ([]ContainerFileEntry, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.StatusValue.State != StateRunning {
		return nil, ErrRuntimeNotRunning
	}

	found := false
	for _, volume := range m.Volumes {
		if volume.Name == name {
			found = true
			break
		}
	}

	if !found {
		return nil, fmt.Errorf("volume %s not found", name)
	}

	if path == "" {
		path = "/"
	}

	switch path {
	case "/":
		return []ContainerFileEntry{
			{Name: "app", Path: "/app", IsDir: true, Size: 0, Mode: "drwxr-xr-x", Modified: "5 months ago"},
			{Name: "dump.rdb", Path: "/dump.rdb", IsDir: false, Size: 88, Mode: "-rw-------", Modified: "7 months ago"},
		}, nil
	case "/app":
		return []ContainerFileEntry{
			{Name: "data.txt", Path: "/app/data.txt", IsDir: false, Size: 12, Mode: "-rw-r--r--", Modified: "2 days ago"},
		}, nil
	default:
		return []ContainerFileEntry{}, nil
	}
}

func (m *Mock) VolumeContainers(_ context.Context, name string) ([]VolumeContainerUsage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.StatusValue.State != StateRunning {
		return nil, ErrRuntimeNotRunning
	}

	found := false
	for _, volume := range m.Volumes {
		if volume.Name == name {
			found = true
			break
		}
	}

	if !found {
		return nil, fmt.Errorf("volume %s not found", name)
	}

	if len(m.Containers) == 0 {
		return []VolumeContainerUsage{}, nil
	}

	container := m.Containers[0]
	return []VolumeContainerUsage{
		{
			ID:     container.ID,
			Name:   container.Name,
			Image:  container.Image,
			Port:   extractHostPort(container.Ports),
			Target: "/data",
		},
	}, nil
}

func (m *Mock) RunBuild(_ context.Context, _, tag, dockerfile, platform string) (BuildResult, error) {
	if m.ImageErr != nil {
		return BuildResult{}, m.ImageErr
	}

	output := `#1 [internal] load build definition from Dockerfile
#1 DONE 0.0s
#2 [1/2] FROM alpine:latest
#2 CACHED
#3 [2/2] RUN echo hello
#3 DONE 0.1s
`
	result := ParseBuildOutput(output)
	result = enrichBuildResult(context.Background(), func(ctx context.Context, command string, args ...string) ([]byte, error) {
		return []byte("{}"), nil
	}, ".", dockerfile, tag, platform, result)

	return result, nil
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

func (m *Mock) PushImage(_ context.Context, ref string) error {
	if m.ImageErr != nil {
		return m.ImageErr
	}

	_ = ref
	return nil
}

func (m *Mock) RunImage(_ context.Context, ref string) (string, error) {
	if m.ImageErr != nil {
		return "", m.ImageErr
	}

	if m.StatusValue.State != StateRunning {
		return "", ErrRuntimeNotRunning
	}

	_ = ref
	return "mock-container-id", nil
}

func (m *Mock) StreamLogs(_ context.Context, _ string, output func(string)) error {
	for _, line := range m.LogLines {
		output(line)
	}

	return nil
}

func (m *Mock) StreamLogsFollow(_ context.Context, _ string, _ func(string)) error {
	return nil
}

func (m *Mock) InspectContainer(_ context.Context, id string) (json.RawMessage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.ContainerErr != nil {
		return nil, m.ContainerErr
	}

	name := id
	for _, container := range m.Containers {
		if container.ID == id {
			name = container.Name
			break
		}
	}

	payload := fmt.Sprintf(`{
		"Id": %q,
		"Name": "/%s",
		"Config": {"Image": "hello-world", "Env": ["PATH=/usr/bin"], "Cmd": ["sh"]},
		"HostConfig": {"Binds": ["/host/data:/data:rw"]},
		"Mounts": [{"Type":"bind","Source":"/host/data","Destination":"/data","Mode":"rw","RW":true}],
		"State": {"Status": "running", "ExitCode": 0}
	}`, id, name)

	return json.RawMessage(payload), nil
}

func (m *Mock) ContainerMounts(ctx context.Context, id string) ([]ContainerMount, error) {
	inspect, err := m.InspectContainer(ctx, id)
	if err != nil {
		return nil, err
	}

	return parseContainerMounts(inspect)
}

func (m *Mock) ListContainerFiles(_ context.Context, _, path string) ([]ContainerFileEntry, error) {
	if m.ContainerErr != nil {
		return nil, m.ContainerErr
	}

	if path == "" {
		path = "/"
	}

	return []ContainerFileEntry{
		{Name: "app", Path: pathJoin(path, "app"), IsDir: true, Size: 0, Mode: "drwxr-xr-x", Modified: "5 months ago"},
		{Name: ".dockerenv", Path: pathJoin(path, ".dockerenv"), IsDir: false, Size: 0, Mode: "-rw-r--r--", Modified: "13 seconds ago"},
		{Name: "bin", Path: pathJoin(path, "bin"), IsDir: true, Size: 0, Mode: "drwxr-xr-x", Modified: "2 years ago", Note: "usr/bin"},
	}, nil
}

func pathJoin(base, name string) string {
	if base == "/" {
		return "/" + name
	}
	return base + "/" + name
}

func (m *Mock) ExecContainer(_ context.Context, _, command string) (string, error) {
	if m.ContainerErr != nil {
		return "", m.ContainerErr
	}

	return "# " + command + "\nmock output", nil
}

func (m *Mock) AttachExec(ctx context.Context, id string, stdin io.Reader, onOutput func([]byte), resizeCh <-chan ExecResize) error {
	if m.ContainerErr != nil {
		return m.ContainerErr
	}

	onOutput([]byte("# mock shell in container " + id + "\r\n# "))

	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case _, ok := <-resizeCh:
				if !ok {
					return
				}
			}
		}
	}()

	buffer := make([]byte, 4096)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
			n, err := stdin.Read(buffer)
			if n > 0 {
				onOutput(append([]byte(nil), buffer[:n]...))
			}
			if err != nil {
				return err
			}
		}
	}
}

func (m *Mock) ContainerStats(_ context.Context, _ string) (ContainerStats, error) {
	if m.ContainerErr != nil {
		return ContainerStats{}, m.ContainerErr
	}

	return ContainerStats{
		CPUPerc:  "0.00%",
		MemUsage: "32.77MB / 7.65GB",
		MemPerc:  "0.42%",
		NetIO:    "1.17KB / 126B",
		BlockIO:  "1.52MB / 4.1KB",
		PIDs:     "5",
	}, nil
}

func (m *Mock) RestartContainer(ctx context.Context, id string) error {
	if err := m.StopContainer(ctx, id); err != nil {
		return err
	}

	return m.StartContainer(ctx, id)
}

func (m *Mock) RegistryStatus(_ context.Context) (RegistryStatus, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.StatusValue.State != StateRunning {
		return RegistryStatus{Server: defaultRegistryServer}, nil
	}

	if m.registryLoggedIn {
		return RegistryStatus{LoggedIn: true, Server: defaultRegistryServer, Username: "demo"}, nil
	}

	return RegistryStatus{Server: defaultRegistryServer}, nil
}

func (m *Mock) RegistryLogin(_ context.Context, _, username, password string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.ImageErr != nil {
		return m.ImageErr
	}

	if m.StatusValue.State != StateRunning {
		return ErrRuntimeNotRunning
	}

	if username == "" || password == "" {
		return fmt.Errorf("username and password are required")
	}

	m.registryLoggedIn = true
	return nil
}

func (m *Mock) RegistryLogout(_ context.Context, _ string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.ImageErr != nil {
		return m.ImageErr
	}

	if m.StatusValue.State != StateRunning {
		return ErrRuntimeNotRunning
	}

	m.registryLoggedIn = false
	return nil
}
