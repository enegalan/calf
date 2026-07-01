package runtime

import (
	"context"
	"fmt"
	"os"
	"os/exec"
)

type Native struct {
	dockerSocket string
}

func NewNative(_ string, dockerSocket string) *Native {
	if dockerSocket == "" {
		dockerSocket = "/var/run/docker.sock"
	}

	return &Native{dockerSocket: dockerSocket}
}

func (n *Native) DockerSocket() string {
	return n.dockerSocket
}

func (n *Native) Start(ctx context.Context) error {
	if _, err := os.Stat(n.dockerSocket); err != nil {
		return fmt.Errorf("docker socket not found at %s: ensure containerd/docker is running", n.dockerSocket)
	}

	if _, err := runCommand(ctx, "systemctl", "is-active", "containerd"); err != nil {
		if _, fallbackErr := runCommand(ctx, "nerdctl", "info"); fallbackErr != nil {
			return fmt.Errorf("native runtime unavailable: %w", fallbackErr)
		}
	}

	return nil
}

func (n *Native) Stop(_ context.Context) error {
	return nil
}

func (n *Native) Status(ctx context.Context) (Status, error) {
	status := Status{
		Mode:         ModeNative,
		State:        StateStopped,
		DockerSocket: n.dockerSocket,
	}

	if _, err := os.Stat(n.dockerSocket); err == nil {
		status.State = StateRunning
	}

	if _, err := runCommand(ctx, "nerdctl", "info"); err != nil {
		if status.State == StateRunning {
			return status, nil
		}

		return status, err
	}

	status.State = StateRunning
	return status, nil
}

func (n *Native) ListContainers(ctx context.Context) ([]Container, error) {
	return listContainers(ctx, n.runLocal)
}

func (n *Native) ListImages(ctx context.Context) ([]Image, error) {
	return listImages(ctx, n.runLocal)
}

func (n *Native) StartContainer(ctx context.Context, id string) error {
	_, err := n.runLocal(ctx, "nerdctl", "start", id)
	return err
}

func (n *Native) StopContainer(ctx context.Context, id string) error {
	_, err := n.runLocal(ctx, "nerdctl", "stop", id)
	return err
}

func (n *Native) RemoveContainer(ctx context.Context, id string) error {
	_, err := n.runLocal(ctx, "nerdctl", "rm", "-f", id)
	return err
}

func (n *Native) RemoveImage(ctx context.Context, ref string) error {
	_, err := n.runLocal(ctx, "nerdctl", "rmi", ref)
	return err
}

func (n *Native) PullImage(ctx context.Context, ref string) error {
	_, err := n.runLocal(ctx, "nerdctl", "pull", ref)
	return err
}

func (n *Native) StreamLogs(ctx context.Context, id string, output func(string)) error {
	command := exec.CommandContext(ctx, "nerdctl", "logs", "-f", id)
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

func (n *Native) runLocal(ctx context.Context, command string, args ...string) ([]byte, error) {
	if command == "nerdctl" {
		return runCommand(ctx, command, args...)
	}

	return runCommand(ctx, command, args...)
}
