package runtime

import (
	"context"
	_ "embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

//go:embed lima.yaml
var limaTemplate string

type Lima struct {
	vmName       string
	dockerSocket string
	templatePath string
}

func NewLima(vmName string, dockerSocket string) *Lima {
	if vmName == "" {
		vmName = "calf"
	}

	if dockerSocket == "" {
		dockerSocket = defaultDockerSocket()
	}

	return &Lima{
		vmName:       vmName,
		dockerSocket: dockerSocket,
	}
}

func (l *Lima) DockerSocket() string {
	return l.dockerSocket
}

func (l *Lima) Start(ctx context.Context) error {
	if _, err := exec.LookPath("limactl"); err != nil {
		return fmt.Errorf("limactl not found: install Lima first")
	}

	if err := l.ensureTemplate(); err != nil {
		return err
	}

	exists, err := l.instanceExists(ctx)
	if err != nil {
		return err
	}

	if !exists {
		if _, err := runCommand(ctx, "limactl", "create", "--name", l.vmName, l.templatePath); err != nil {
			return err
		}
	}

	if _, err := runCommand(ctx, "limactl", "start", l.vmName); err != nil {
		return err
	}

	return nil
}

func (l *Lima) Stop(ctx context.Context) error {
	if _, err := exec.LookPath("limactl"); err != nil {
		return fmt.Errorf("limactl not found: install Lima first")
	}

	exists, err := l.instanceExists(ctx)
	if err != nil {
		return err
	}

	if !exists {
		return nil
	}

	_, err = runCommand(ctx, "limactl", "stop", l.vmName)
	return err
}

func (l *Lima) Status(ctx context.Context) (Status, error) {
	status := Status{
		Mode:         ModeVM,
		State:        StateStopped,
		DockerSocket: l.dockerSocket,
		VMName:       l.vmName,
	}

	if _, err := exec.LookPath("limactl"); err != nil {
		return status, nil
	}

	output, err := runCommand(ctx, "limactl", "list", "--format", "{{.Name}}\t{{.Status}}")
	if err != nil {
		return status, err
	}

	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) != 2 || fields[0] != l.vmName {
			continue
		}

		if strings.Contains(strings.ToLower(fields[1]), "running") {
			status.State = StateRunning
		}
	}

	return status, nil
}

func (l *Lima) ListContainers(ctx context.Context) ([]Container, error) {
	return listContainers(ctx, l.runInVM)
}

func (l *Lima) ListImages(ctx context.Context) ([]Image, error) {
	return listImages(ctx, l.runInVM)
}

func (l *Lima) StartContainer(ctx context.Context, id string) error {
	_, err := l.runInVM(ctx, "nerdctl", "start", id)
	return err
}

func (l *Lima) StopContainer(ctx context.Context, id string) error {
	_, err := l.runInVM(ctx, "nerdctl", "stop", id)
	return err
}

func (l *Lima) RemoveContainer(ctx context.Context, id string) error {
	_, err := l.runInVM(ctx, "nerdctl", "rm", "-f", id)
	return err
}

func (l *Lima) RemoveImage(ctx context.Context, ref string) error {
	_, err := l.runInVM(ctx, "nerdctl", "rmi", ref)
	return err
}

func (l *Lima) PullImage(ctx context.Context, ref string) error {
	_, err := l.runInVM(ctx, "nerdctl", "pull", ref)
	return err
}

func (l *Lima) StreamLogs(ctx context.Context, id string, output func(string)) error {
	command := exec.CommandContext(ctx, "limactl", "shell", l.vmName, "--", "nerdctl", "logs", "-f", id)
	stdout, err := command.StdoutPipe()
	if err != nil {
		return err
	}

	stderr, err := command.StderrPipe()
	if err != nil {
		return err
	}

	if err := command.Start(); err != nil {
		return err
	}

	go pipeLines(stdout, output)
	go pipeLines(stderr, output)

	return command.Wait()
}

func (l *Lima) runInVM(ctx context.Context, command string, args ...string) ([]byte, error) {
	shellArgs := append([]string{"shell", l.vmName, "--", command}, args...)
	return runCommand(ctx, "limactl", shellArgs...)
}

func (l *Lima) instanceExists(ctx context.Context) (bool, error) {
	output, err := runCommand(ctx, "limactl", "list", "--format", "{{.Name}}")
	if err != nil {
		return false, err
	}

	for _, name := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		if name == l.vmName {
			return true, nil
		}
	}

	return false, nil
}

func (l *Lima) ensureTemplate() error {
	path, err := l.templateFile()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Join(filepath.Dir(path), "mounts"), 0o755); err != nil {
		return err
	}

	if _, err := os.Stat(path); err == nil {
		l.templatePath = path
		return nil
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}

	content := fmt.Sprintf(limaTemplate, home, home)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		return err
	}

	l.templatePath = path
	return nil
}

func (l *Lima) templateFile() (string, error) {
	configDir, err := configDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(configDir, "lima.yaml"), nil
}

func configDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(home, ".config", "calf"), nil
}

func defaultDockerSocket() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}

	return filepath.Join(home, ".config", "calf", "docker.sock")
}
