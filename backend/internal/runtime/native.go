package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
)

type Native struct {
	dockerSocket string
}

func NewNative(_ string, dockerSocket string, _, _, _, _ int) *Native {
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
	return emptyContainersIfStopped(ctx, n.Status, func(ctx context.Context) ([]Container, error) {
		return listContainers(ctx, n.runLocal)
	})
}

func (n *Native) ListImages(ctx context.Context) ([]Image, error) {
	return emptyImagesIfStopped(ctx, n.Status, func(ctx context.Context) ([]Image, error) {
		return listImages(ctx, n.runLocal)
	})
}

func (n *Native) ImageHistory(ctx context.Context, ref string) ([]ImageLayer, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return nil, err
	}

	return imageHistory(ctx, n.runLocal, ref)
}

func (n *Native) ListVolumes(ctx context.Context) ([]Volume, error) {
	return emptyVolumesIfStopped(ctx, n.Status, func(ctx context.Context) ([]Volume, error) {
		return listVolumes(ctx, n.runLocal)
	})
}

func (n *Native) CreateVolume(ctx context.Context, name string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	args := []string{"volume", "create"}
	if name != "" {
		args = append(args, name)
	}

	_, err := n.runLocal(ctx, "nerdctl", args...)
	return err
}

func (n *Native) RemoveVolume(ctx context.Context, name string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	_, err := n.runLocal(ctx, "nerdctl", "volume", "rm", name)
	return err
}

func (n *Native) RunBuild(ctx context.Context, contextPath, tag, dockerfile string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	return runBuild(ctx, n.runLocal, contextPath, tag, dockerfile)
}

func (n *Native) StartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	_, err := n.runLocal(ctx, "nerdctl", "start", id)
	return err
}

func (n *Native) StopContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	_, err := n.runLocal(ctx, "nerdctl", "stop", id)
	return err
}

func (n *Native) RemoveContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	_, err := n.runLocal(ctx, "nerdctl", "rm", "-f", id)
	return err
}

func (n *Native) RemoveImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	_, err := n.runLocal(ctx, "nerdctl", "rmi", ref)
	return err
}

func (n *Native) PullImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	_, err := n.runLocal(ctx, "nerdctl", "pull", ref)
	return err
}

func (n *Native) PushImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	_, err := n.runLocal(ctx, "nerdctl", "push", ref)
	return err
}

func (n *Native) RunImage(ctx context.Context, ref string) (string, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return "", err
	}

	return runImage(ctx, n.runLocal, ref)
}

func (n *Native) StreamLogs(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}
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

func (n *Native) InspectContainer(ctx context.Context, id string) (json.RawMessage, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return nil, err
	}

	return inspectContainer(ctx, n.runLocal, id)
}

func (n *Native) ContainerMounts(ctx context.Context, id string) ([]ContainerMount, error) {
	inspect, err := n.InspectContainer(ctx, id)
	if err != nil {
		return nil, err
	}

	return parseContainerMounts(inspect)
}

func (n *Native) ListContainerFiles(ctx context.Context, id, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return nil, err
	}

	if !isValidContainerPath(path) {
		return nil, fmt.Errorf("invalid path")
	}

	return listContainerFiles(ctx, n.runLocal, id, path)
}

func (n *Native) ExecContainer(ctx context.Context, id, command string) (string, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return "", err
	}

	return execInContainer(ctx, n.runLocal, id, command)
}

func (n *Native) AttachExec(ctx context.Context, id string, stdin io.Reader, onOutput func([]byte), resizeCh <-chan ExecResize) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	command := exec.CommandContext(ctx, "nerdctl", "exec", "-it", id, "/bin/sh")
	return attachExecInContainer(ctx, command, stdin, onOutput, resizeCh)
}

func (n *Native) ContainerStats(ctx context.Context, id string) (ContainerStats, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return ContainerStats{}, err
	}

	return containerStats(ctx, n.runLocal, id)
}

func (n *Native) RestartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	return restartContainer(ctx, n.runLocal, id)
}

func (n *Native) runLocal(ctx context.Context, command string, args ...string) ([]byte, error) {
	if command == "nerdctl" {
		return runCommand(ctx, command, args...)
	}

	return runCommand(ctx, command, args...)
}

func (n *Native) runLocalWithStdin(ctx context.Context, stdin, command string, args ...string) ([]byte, error) {
	if command == "nerdctl" {
		return runCommandWithStdin(ctx, stdin, command, args...)
	}

	return runCommandWithStdin(ctx, stdin, command, args...)
}

func (n *Native) registryConfigPaths() []string {
	home, err := os.UserHomeDir()
	if err != nil {
		return []string{"/root/.docker/config.json"}
	}

	return []string{
		filepath.Join(home, ".docker", "config.json"),
		"/root/.docker/config.json",
	}
}

func (n *Native) RegistryStatus(ctx context.Context) (RegistryStatus, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return RegistryStatus{Server: defaultRegistryServer}, nil
	}

	return registryStatus(ctx, n.runLocal, n.registryConfigPaths()...)
}

func (n *Native) RegistryLogin(ctx context.Context, server, username, password string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	return registryLogin(ctx, n.runLocal, n.runLocalWithStdin, server, username, password)
}

func (n *Native) RegistryLogout(ctx context.Context, server string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	return registryLogout(ctx, n.runLocal, server)
}
