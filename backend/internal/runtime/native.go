package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/enegalan/calf/backend/internal/constants"
)

// Native represents a native runtime.
type Native struct {
	dockerSocket string
	rootless     bool
	proxy        ProxyConfig
}

// NewNative constructs a Runtime that talks directly to host nerdctl/docker.
func NewNative(_ string, dockerSocket string, _, _, _, _ int, rootless bool, proxy ProxyConfig) *Native {
	socket, usingRootless := ResolveNativeDockerSocket(dockerSocket, rootless)
	return &Native{dockerSocket: socket, rootless: usingRootless, proxy: proxy}
}

// DockerSocket returns the path to the Docker-compatible socket.
func (n *Native) DockerSocket() string {
	return n.dockerSocket
}

// Start verifies the docker socket and container runtime are available.
func (n *Native) Start(ctx context.Context) error {
	if _, err := os.Stat(n.dockerSocket); err != nil {
		if n.rootless {
			return fmt.Errorf("rootless docker socket not found at %s: start rootless Docker (dockerd-rootless) or set docker_socket", n.dockerSocket)
		}
		return fmt.Errorf("docker socket not found at %s: ensure containerd/docker is running", n.dockerSocket)
	}

	if n.rootless {
		if _, err := n.runLocal(ctx, "nerdctl", "info"); err != nil {
			return fmt.Errorf("native rootless runtime unavailable: %w", err)
		}
		return nil
	}

	if _, err := runCommand(ctx, "systemctl", "is-active", "containerd"); err != nil {
		if _, fallbackErr := n.runLocal(ctx, "nerdctl", "info"); fallbackErr != nil {
			return fmt.Errorf("native runtime unavailable: %w", fallbackErr)
		}
	}

	return nil
}

// Stop is a no-op for the native runtime; the host daemon keeps running.
func (n *Native) Stop(_ context.Context) error {
	return nil
}

// Status reports native mode and whether the docker socket responds.
func (n *Native) Status(ctx context.Context) (Status, error) {
	status := Status{
		Mode:         Mode(constants.RuntimeModeNative),
		State:        State(constants.RuntimeStateStopped),
		DockerSocket: n.dockerSocket,
		Rootless:     n.rootless,
	}

	if _, err := os.Stat(n.dockerSocket); err == nil {
		status.State = State(constants.RuntimeStateRunning)
	}

	if _, err := n.runLocal(ctx, "nerdctl", "info"); err != nil {
		if status.State == State(constants.RuntimeStateRunning) {
			return status, nil
		}

		return status, err
	}

	status.State = State(constants.RuntimeStateRunning)
	return status, nil
}

// ListContainers returns all containers, or none when the runtime is stopped.
func (n *Native) ListContainers(ctx context.Context) ([]Container, error) {
	return emptyIfStopped(ctx, n.Status, func(ctx context.Context) ([]Container, error) {
		return listContainers(ctx, n.runLocal)
	})
}

// ListImages returns all images, or none when the runtime is stopped.
func (n *Native) ListImages(ctx context.Context) ([]Image, error) {
	return emptyIfStopped(ctx, n.Status, func(ctx context.Context) ([]Image, error) {
		return listImages(ctx, n.runLocal)
	})
}

// ImageHistory returns build layers for the given image reference.
func (n *Native) ImageHistory(ctx context.Context, ref string) ([]ImageLayer, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return nil, err
	}

	return imageHistory(ctx, n.runLocal, ref)
}

// ListVolumes returns all volumes with in-use enrichment, or none when stopped.
func (n *Native) ListVolumes(ctx context.Context) ([]Volume, error) {
	return emptyIfStopped(ctx, n.Status, func(ctx context.Context) ([]Volume, error) {
		volumes, err := listVolumes(ctx, n.runLocal)
		if err != nil {
			return nil, err
		}

		return enrichVolumesInUse(ctx, n.runLocal, volumes)
	})
}

// ListNetworks returns all networks, or none when the runtime is stopped.
func (n *Native) ListNetworks(ctx context.Context) ([]Network, error) {
	return emptyIfStopped(ctx, n.Status, func(ctx context.Context) ([]Network, error) {
		return listNetworks(ctx, n.runLocal)
	})
}

// InspectNetwork returns detailed metadata for a network by name.
func (n *Native) InspectNetwork(ctx context.Context, name string) (NetworkDetail, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return NetworkDetail{}, err
	}

	return inspectNetwork(ctx, n.runLocal, name)
}

// RemoveNetwork deletes a network by name.
func (n *Native) RemoveNetwork(ctx context.Context, name string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	return removeNetwork(ctx, n.runLocal, name)
}

// ApplyProxy stores proxy settings and applies them when the runtime is running.
func (n *Native) ApplyProxy(ctx context.Context, proxy ProxyConfig) error {
	n.proxy = proxy

	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	if n.rootless {
		// Rootless engines pick up HTTP(S)_PROXY from the process environment
		// (see commandEnv); system-wide systemd drop-ins require root.
		return nil
	}

	return applyProxyInVM(ctx, n.runLocal, proxy)
}

// CreateVolume creates a named volume, or an anonymous one when name is empty.
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

// CloneVolume copies data from source into a new dest volume.
func (n *Native) CloneVolume(ctx context.Context, source, dest string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	return cloneVolume(ctx, n.runLocal, source, dest)
}

// ExportVolume archives a volume to the destination described by opts.
func (n *Native) ExportVolume(ctx context.Context, opts VolumeExportOptions) (string, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return "", err
	}

	return RunVolumeExport(ctx, n.runLocal, opts)
}

// RemoveVolume deletes a volume by name.
func (n *Native) RemoveVolume(ctx context.Context, name string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	_, err := n.runLocal(ctx, "nerdctl", "volume", "rm", name)
	return err
}

// InspectVolume returns detailed metadata for a volume by name.
func (n *Native) InspectVolume(ctx context.Context, name string) (VolumeDetail, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return VolumeDetail{}, err
	}

	return inspectVolume(ctx, n.runLocal, name)
}

// ListVolumeFiles lists directory entries inside a volume at path.
func (n *Native) ListVolumeFiles(ctx context.Context, name, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return nil, err
	}

	if !isValidContainerPath(path) {
		return nil, fmt.Errorf("invalid path")
	}

	return listVolumeFiles(ctx, n.runLocal, name, path)
}

// VolumeContainers lists containers that mount the named volume.
func (n *Native) VolumeContainers(ctx context.Context, name string) ([]VolumeContainerUsage, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return nil, err
	}

	return volumeContainerUsages(ctx, n.runLocal, name)
}

// RunBuild builds an image from contextPath and returns parsed build output.
func (n *Native) RunBuild(ctx context.Context, contextPath, tag, dockerfile, platform string) (BuildResult, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return BuildResult{}, err
	}

	return runBuild(ctx, n.runLocal, contextPath, tag, dockerfile, platform)
}

// StartContainer starts a stopped container by ID.
func (n *Native) StartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	_, err := n.runLocal(ctx, "nerdctl", "start", id)
	return err
}

// StopContainer stops a running container by ID.
func (n *Native) StopContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	_, err := n.runLocal(ctx, "nerdctl", "stop", id)
	return err
}

// RemoveContainer force-removes a container by ID.
func (n *Native) RemoveContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	_, err := n.runLocal(ctx, "nerdctl", "rm", "-f", id)
	return err
}

// RemoveImage deletes an image by reference.
func (n *Native) RemoveImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	_, err := n.runLocal(ctx, "nerdctl", "rmi", ref)
	return err
}

// PullImage downloads an image from a registry.
func (n *Native) PullImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	_, err := n.runLocal(ctx, "nerdctl", "pull", ref)
	return err
}

// PushImage uploads an image to a registry.
func (n *Native) PushImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	return pushImage(ctx, n.runLocal, ref)
}

// RunImage starts a detached container from ref and returns its ID.
func (n *Native) RunImage(ctx context.Context, ref string) (string, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return "", err
	}

	return runImage(ctx, n.runLocal, ref)
}

// StreamLogs tails recent history then follows new log lines for a container.
func (n *Native) StreamLogs(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	history, err := n.runLocal(ctx, "nerdctl", "logs", "--tail", logTailLines, id)
	if err == nil {
		emitLogLines(output, history)
	}

	return n.streamLogsFollow(ctx, id, logsFollowSince(), output)
}

// StreamLogsFollow streams only new log lines from the current time onward.
func (n *Native) StreamLogsFollow(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	return n.streamLogsFollow(ctx, id, logsFollowSince(), output)
}

// streamLogsFollow runs nerdctl logs -f and pipes lines to output.
func (n *Native) streamLogsFollow(ctx context.Context, id, since string, output func(string)) error {
	command := exec.CommandContext(ctx, "nerdctl", "logs", "-f", "--since", since, id)
	command.Env = n.commandEnv()
	return streamCommandLogs(ctx, command, output)
}

// InspectContainer returns raw nerdctl inspect JSON for a container.
func (n *Native) InspectContainer(ctx context.Context, id string) (json.RawMessage, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return nil, err
	}

	return inspectContainer(ctx, n.runLocal, id)
}

// ContainerMounts parses mount points from container inspect data.
func (n *Native) ContainerMounts(ctx context.Context, id string) ([]ContainerMount, error) {
	inspect, err := n.InspectContainer(ctx, id)
	if err != nil {
		return nil, err
	}

	return parseContainerMounts(inspect)
}

// ListContainerFiles lists directory entries inside a container at path.
func (n *Native) ListContainerFiles(ctx context.Context, id, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return nil, err
	}

	if !isValidContainerPath(path) {
		return nil, fmt.Errorf("invalid path")
	}

	return listContainerFiles(ctx, n.runLocal, id, path)
}

// ExecContainer runs a one-shot command inside a container and returns stdout.
func (n *Native) ExecContainer(ctx context.Context, id, command string) (string, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return "", err
	}

	return execInContainer(ctx, n.runLocal, id, command)
}

// AttachExec opens an interactive PTY session inside a container.
func (n *Native) AttachExec(ctx context.Context, id string, stdin io.Reader, onOutput func([]byte), resizeCh <-chan ExecResize) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	command := exec.CommandContext(ctx, "nerdctl", interactiveExecArgs(id)...)
	command.Env = n.commandEnv()
	return attachContainerExec(ctx, command, stdin, onOutput, resizeCh)
}

// ContainerStats returns CPU and memory usage for a running container.
func (n *Native) ContainerStats(ctx context.Context, id string) (ContainerStats, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return ContainerStats{}, err
	}

	return containerStats(ctx, n.runLocal, id)
}

// RestartContainer stops and starts a container by ID.
func (n *Native) RestartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	return restartContainer(ctx, n.runLocal, id)
}

// runLocal executes a host command, retrying transient nerdctl failures.
func (n *Native) runLocal(ctx context.Context, command string, args ...string) ([]byte, error) {
	env := n.commandEnv()
	if command == "nerdctl" {
		return runCommandWithRetryEnv(ctx, constants.DefaultCommandRetries, constants.DefaultCommandRetryDelay, env, "", command, args...)
	}

	return runCommandOnceEnv(ctx, env, "", command, args...)
}

// runLocalWithStdin executes a host command with stdin, retrying nerdctl on transient errors.
func (n *Native) runLocalWithStdin(ctx context.Context, stdin, command string, args ...string) ([]byte, error) {
	env := n.commandEnv()
	if command == "nerdctl" {
		return runCommandWithRetryEnv(ctx, constants.DefaultCommandRetries, constants.DefaultCommandRetryDelay, env, stdin, command, args...)
	}

	return runCommandOnceEnv(ctx, env, stdin, command, args...)
}

// commandEnv returns the process environment, including DOCKER_HOST and optional proxy vars.
func (n *Native) commandEnv() []string {
	if n.dockerSocket == "" && n.proxy == (ProxyConfig{}) {
		return nil
	}
	env := os.Environ()
	if n.dockerSocket != "" {
		env = dockerHostEnvFrom(env, n.dockerSocket)
	}
	if n.proxy != (ProxyConfig{}) {
		env = proxyEnvFrom(env, n.proxy)
	}
	return env
}

// registryConfigPaths returns Docker config.json paths checked for registry auth.
func (n *Native) registryConfigPaths() []string {
	home, err := os.UserHomeDir()
	if err != nil {
		if n.rootless {
			return nil
		}
		return []string{"/root/.docker/config.json"}
	}

	paths := []string{filepath.Join(home, ".docker", "config.json")}
	if !n.rootless {
		paths = append(paths, "/root/.docker/config.json")
	}
	return paths
}

// RegistryStatus reports whether the user is logged in to the default registry.
func (n *Native) RegistryStatus(ctx context.Context) (RegistryStatus, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return RegistryStatus{Server: constants.DefaultRegistryServer}, nil
	}

	return registryStatus(ctx, n.runLocal, n.registryConfigPaths()...)
}

// RegistryLogin authenticates to a container registry with username and password.
func (n *Native) RegistryLogin(ctx context.Context, server, username, password string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	return registryLogin(ctx, n.runLocal, n.runLocalWithStdin, server, username, password)
}

// RegistryLogout removes stored credentials for a registry server.
func (n *Native) RegistryLogout(ctx context.Context, server string) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	return registryLogout(ctx, n.runLocal, server)
}
