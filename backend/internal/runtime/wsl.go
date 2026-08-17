package runtime

import (
	"context"
	"fmt"
	"io"
	"os/exec"
	goruntime "runtime"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/enegalan/calf/backend/internal/constants"
)

const defaultWSLDistro = "calf"

// WSL is the Windows container engine: Docker Engine inside a WSL 2 distro.
type WSL struct {
	cliOps
	mu             sync.Mutex
	dockerSocket   string
	distro         string
	started        atomic.Bool
	engineSettings EngineSettings
}

// NewWSL constructs a Runtime that shells to `wsl -d <distro> -- docker`.
func NewWSL(_ string, dockerSocket string, _, _, _, _ int, _ bool, _ ProxyConfig) *WSL {
	if dockerSocket == "" {
		dockerSocket = `npipe:////./pipe/calf-engine`
	}
	w := &WSL{dockerSocket: dockerSocket, distro: defaultWSLDistro}
	w.cliOps = cliOps{status: w.Status, runLocal: w.runLocal, runLocalWithStdin: w.runLocalWithStdin}
	return w
}

// DockerSocket returns the host Docker endpoint advertised to the CLI.
func (w *WSL) DockerSocket() string {
	return w.dockerSocket
}

// ApplyEngineSettings stores overlay fields for the WSL engine.
func (w *WSL) ApplyEngineSettings(settings EngineSettings) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.engineSettings = settings
}

// Start starts dockerd inside the calf WSL distro.
func (w *WSL) Start(ctx context.Context) error {
	if goruntime.GOOS != "windows" {
		return fmt.Errorf("WSL engine requires Windows")
	}
	if _, err := exec.LookPath("wsl"); err != nil {
		return fmt.Errorf("WSL is not installed; install WSL 2 from Microsoft")
	}
	if _, err := w.runWSL(ctx, "true"); err != nil {
		return fmt.Errorf("WSL distro %q is not installed; import a calf rootfs or create the distro: %w", w.distro, err)
	}
	if _, err := w.runWSL(ctx, "service docker start || dockerd >/dev/null 2>&1 &"); err != nil {
		return fmt.Errorf("start docker in WSL distro %s: %w", w.distro, err)
	}
	w.started.Store(true)
	return nil
}

// Stop pauses dockerd inside the WSL distro (the shared WSL VM stays up).
func (w *WSL) Stop(ctx context.Context) error {
	if !w.started.Load() {
		return nil
	}
	_, _ = w.runWSL(ctx, "service docker stop || killall dockerd >/dev/null 2>&1 || true")
	w.started.Store(false)
	return nil
}

// ForceStop stops dockerd inside the WSL distro.
func (w *WSL) ForceStop(ctx context.Context) error {
	return w.Stop(ctx)
}

// Status reports whether the WSL docker engine is running.
func (w *WSL) Status(ctx context.Context) (Status, error) {
	state := State(constants.RuntimeStateStopped)
	if w.started.Load() {
		if _, err := w.runLocal(ctx, "nerdctl", "info"); err == nil {
			state = State(constants.RuntimeStateRunning)
		}
	}
	return Status{
		Mode:         Mode(constants.RuntimeModeVM),
		State:        state,
		DockerSocket: w.dockerSocket,
		VMName:       w.distro,
	}, nil
}

// ResourceUsage returns zeros until WSL cgroup probes exist.
func (w *WSL) ResourceUsage(context.Context) (ResourceUsage, error) {
	return ResourceUsage{}, nil
}

// ListContainers returns containers from the WSL docker engine.
func (w *WSL) ListContainers(ctx context.Context) ([]Container, error) {
	return emptyIfStopped(ctx, w.Status, func(ctx context.Context) ([]Container, error) {
		return listContainers(ctx, w.runLocal)
	})
}

// ListVolumeFiles lists volume files inside the WSL distro.
func (w *WSL) ListVolumeFiles(ctx context.Context, name, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, w.Status); err != nil {
		return nil, err
	}
	if !isValidContainerPath(path) {
		return nil, fmt.Errorf("invalid path")
	}
	return listVolumeFiles(ctx, w.runLocal, name, path)
}

// RunBuild builds an image inside the WSL distro.
func (w *WSL) RunBuild(ctx context.Context, contextPath, tag, dockerfile, platform string) (BuildResult, error) {
	if err := requireRunning(ctx, w.Status); err != nil {
		return BuildResult{}, err
	}
	return runBuild(ctx, w.runLocal, contextPath, tag, dockerfile, platform)
}

// StreamLogs tails recent history then follows new log lines for a container.
func (w *WSL) StreamLogs(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, w.Status); err != nil {
		return err
	}
	history, err := w.runLocal(ctx, "nerdctl", "logs", "--tail", logTailLines, id)
	if err == nil {
		emitLogLines(output, history)
	}
	return w.streamLogsFollow(ctx, id, logsFollowSince(), output)
}

// StreamLogsFollow streams only new log lines from the current time onward.
func (w *WSL) StreamLogsFollow(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, w.Status); err != nil {
		return err
	}
	return w.streamLogsFollow(ctx, id, logsFollowSince(), output)
}

func (w *WSL) streamLogsFollow(ctx context.Context, id, since string, output func(string)) error {
	command := exec.CommandContext(ctx, "wsl", "-d", w.distro, "-u", "root", "--", "docker", "logs", "-f", "--since", since, id)
	return streamCommandLogs(ctx, command, output)
}

// AttachExec opens an interactive session inside a container in the WSL distro.
func (w *WSL) AttachExec(ctx context.Context, id string, stdin io.Reader, onOutput func([]byte), resizeCh <-chan ExecResize) error {
	if err := requireRunning(ctx, w.Status); err != nil {
		return err
	}
	args := append([]string{"-d", w.distro, "-u", "root", "--", "docker"}, interactiveExecArgs(id)...)
	command := exec.CommandContext(ctx, "wsl", args...)
	return attachContainerExec(ctx, command, stdin, onOutput, resizeCh)
}

// ApplyProxy is a no-op until dockerd in WSL reads calf proxy settings.
func (w *WSL) ApplyProxy(_ context.Context, _ ProxyConfig) error {
	return nil
}

// RegistryStatus reports registry login using docker config inside the distro.
func (w *WSL) RegistryStatus(ctx context.Context) (RegistryStatus, error) {
	return registryStatus(ctx, w.runLocal, w.runLocalWithStdin)
}

func (w *WSL) runLocal(ctx context.Context, command string, args ...string) ([]byte, error) {
	return w.runWSL(ctx, dockerWSLCommand(command, args...))
}

func (w *WSL) runLocalWithStdin(ctx context.Context, stdin, command string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "wsl", "-d", w.distro, "-u", "root", "--", "sh", "-c", dockerWSLCommand(command, args...))
	cmd.Stdin = strings.NewReader(stdin)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return output, fmt.Errorf("wsl %s: %w: %s", w.distro, err, strings.TrimSpace(string(output)))
	}
	return output, nil
}

func (w *WSL) runWSL(ctx context.Context, shell string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "wsl", "-d", w.distro, "-u", "root", "--", "sh", "-c", shell)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return output, fmt.Errorf("wsl %s: %w: %s", w.distro, err, strings.TrimSpace(string(output)))
	}
	return output, nil
}

// dockerWSLCommand maps nerdctl invocations onto docker inside the WSL distro.
func dockerWSLCommand(command string, args ...string) string {
	parts := make([]string, 0, len(args)+1)
	if command == "nerdctl" {
		parts = append(parts, "docker")
	} else {
		parts = append(parts, command)
	}
	parts = append(parts, args...)
	quoted := make([]string, 0, len(parts))
	for _, part := range parts {
		quoted = append(quoted, "'"+strings.ReplaceAll(part, "'", `'\''`)+"'")
	}
	return strings.Join(quoted, " ")
}
