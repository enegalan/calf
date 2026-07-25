package runtime

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/enegalan/calf/backend/internal/constants"
)

// Native represents a native runtime. It embeds cliOps for the operations shared with Guest
// (see cli_ops.go); methods with native-specific behavior are defined below.
type Native struct {
	cliOps
	dockerSocket string
	rootless     bool
	proxy        ProxyConfig
}

// NewNative constructs a Runtime that talks directly to host nerdctl/docker.
func NewNative(_ string, dockerSocket string, _, _, _, _ int, rootless bool, proxy ProxyConfig) *Native {
	socket, usingRootless := ResolveNativeDockerSocket(dockerSocket, rootless)
	n := &Native{dockerSocket: socket, rootless: usingRootless, proxy: proxy}
	n.cliOps = cliOps{status: n.Status, runLocal: n.runLocal, runLocalWithStdin: n.runLocalWithStdin}
	return n
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

// ForceStop is a no-op for the native runtime; the host daemon keeps running.
func (n *Native) ForceStop(ctx context.Context) error {
	return n.Stop(ctx)
}

// ResourceUsage returns zeros; native mode has no cheap engine-level probe yet.
func (n *Native) ResourceUsage(_ context.Context) (ResourceUsage, error) {
	return ResourceUsage{}, nil
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

// RunBuild builds an image from contextPath and returns parsed build output.
func (n *Native) RunBuild(ctx context.Context, contextPath, tag, dockerfile, platform string) (BuildResult, error) {
	if err := requireRunning(ctx, n.Status); err != nil {
		return BuildResult{}, err
	}

	return runBuild(ctx, n.runLocal, contextPath, tag, dockerfile, platform)
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

// AttachExec opens an interactive PTY session inside a container.
func (n *Native) AttachExec(ctx context.Context, id string, stdin io.Reader, onOutput func([]byte), resizeCh <-chan ExecResize) error {
	if err := requireRunning(ctx, n.Status); err != nil {
		return err
	}

	command := exec.CommandContext(ctx, "nerdctl", interactiveExecArgs(id)...)
	command.Env = n.commandEnv()
	return attachContainerExec(ctx, command, stdin, onOutput, resizeCh)
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
	// Host Docker credentials; readable whether or not the engine is running.
	return registryStatus(ctx, n.runLocal, n.runLocalWithStdin, n.registryConfigPaths()...)
}
