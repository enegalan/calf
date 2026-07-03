package runtime

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"
)

//go:embed lima.yaml
var limaTemplate string

type Lima struct {
	vmName         string
	dockerSocket   string
	templatePath   string
	cpus           int
	memoryGB       int
	memorySwapGB   int
	diskGB         int
	started        atomic.Bool
	localhostProxy *localhostProxies
}

func NewLima(vmName string, dockerSocket string, cpus int, memoryGB int, memorySwapGB int, diskGB int, apiListenPort int) *Lima {
	if vmName == "" {
		vmName = "calf"
	}

	if dockerSocket == "" {
		dockerSocket = defaultDockerSocket()
	}

	lima := &Lima{
		vmName:         vmName,
		dockerSocket:   dockerSocket,
		cpus:           cpus,
		memoryGB:       memoryGB,
		memorySwapGB:   memorySwapGB,
		diskGB:         diskGB,
		localhostProxy: newLocalhostProxies(),
	}
	lima.localhostProxy.setReservedPorts(apiListenPort)

	return lima
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

	if err := l.waitForNerdctl(ctx); err != nil {
		return err
	}

	l.started.Store(true)
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

	l.localhostProxy.stopAll()
	l.started.Store(false)

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
		return status, nil
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

	if status.State == StateRunning && l.dockerSocket != "" {
		conn, err := net.DialTimeout("unix", l.dockerSocket, 100*time.Millisecond)
		if err != nil {
			status.State = StateStopped
		} else {
			conn.Close()
		}
	}

	status.PortConflicts = l.localhostProxy.conflictsSnapshot()

	return status, nil
}

func (l *Lima) ListContainers(ctx context.Context) ([]Container, error) {
	return emptyContainersIfStopped(ctx, l.Status, func(ctx context.Context) ([]Container, error) {
		if !l.started.Load() {
			return []Container{}, nil
		}

		containers, err := listContainers(ctx, l.runInVM)
		if err == nil {
			l.localhostProxy.sync(publishedTCPPorts(containers))
		}

		return containers, err
	})
}

func (l *Lima) ListImages(ctx context.Context) ([]Image, error) {
	return emptyImagesIfStopped(ctx, l.Status, func(ctx context.Context) ([]Image, error) {
		return listImages(ctx, l.runInVM)
	})
}

func (l *Lima) ImageHistory(ctx context.Context, ref string) ([]ImageLayer, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	return imageHistory(ctx, l.runInVM, ref)
}

func (l *Lima) ListVolumes(ctx context.Context) ([]Volume, error) {
	return emptyVolumesIfStopped(ctx, l.Status, func(ctx context.Context) ([]Volume, error) {
		volumes, err := listVolumes(ctx, l.runInVM)
		if err != nil {
			return nil, err
		}

		return enrichVolumesInUse(ctx, l.runInVM, volumes)
	})
}

func (l *Lima) CreateVolume(ctx context.Context, name string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	args := []string{"volume", "create"}
	if name != "" {
		args = append(args, name)
	}

	_, err := l.runInVM(ctx, "nerdctl", args...)
	return err
}

func (l *Lima) CloneVolume(ctx context.Context, source, dest string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return cloneVolume(ctx, l.runInVM, source, dest)
}

func (l *Lima) RemoveVolume(ctx context.Context, name string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "volume", "rm", name)
	return err
}

func (l *Lima) InspectVolume(ctx context.Context, name string) (VolumeDetail, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return VolumeDetail{}, err
	}

	return inspectVolume(ctx, l.runInVM, name)
}

func (l *Lima) ListVolumeFiles(ctx context.Context, name, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	return listVolumeFiles(ctx, l.runInVM, name, path)
}

func (l *Lima) VolumeContainers(ctx context.Context, name string) ([]VolumeContainerUsage, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	return volumeContainerUsages(ctx, l.runInVM, name)
}

func (l *Lima) RunBuild(ctx context.Context, contextPath, tag, dockerfile string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return runBuild(ctx, l.runInVM, contextPath, tag, dockerfile)
}

func (l *Lima) StartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "start", id)
	return err
}

func (l *Lima) StopContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "stop", id)
	return err
}

func (l *Lima) RemoveContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "rm", "-f", id)
	return err
}

func (l *Lima) RemoveImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "rmi", ref)
	return err
}

func (l *Lima) PullImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "pull", ref)
	return err
}

func (l *Lima) PushImage(ctx context.Context, ref string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	_, err := l.runInVM(ctx, "nerdctl", "push", ref)
	return err
}

func (l *Lima) RunImage(ctx context.Context, ref string) (string, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return "", err
	}

	return runImage(ctx, l.runInVM, ref)
}

func (l *Lima) StreamLogs(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	history, err := l.runInVM(ctx, "nerdctl", "logs", "--tail", logTailLines, id)
	if err == nil {
		emitLogLines(output, history)
	}

	return l.streamLogsFollow(ctx, id, logsFollowSince(), output)
}

func (l *Lima) StreamLogsFollow(ctx context.Context, id string, output func(string)) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return l.streamLogsFollow(ctx, id, logsFollowSince(), output)
}

func (l *Lima) streamLogsFollow(ctx context.Context, id, since string, output func(string)) error {
	command := exec.CommandContext(ctx, "limactl", append([]string{"shell", l.vmName, "--"}, NerdctlVMArgs("logs", "-f", "--since", since, id)...)...)
	command.Env = limaShellEnv()
	return streamCommandLogs(ctx, command, output)
}

func (l *Lima) InspectContainer(ctx context.Context, id string) (json.RawMessage, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	return inspectContainer(ctx, l.runInVM, id)
}

func (l *Lima) ContainerMounts(ctx context.Context, id string) ([]ContainerMount, error) {
	inspect, err := l.InspectContainer(ctx, id)
	if err != nil {
		return nil, err
	}

	return parseContainerMounts(inspect)
}

func (l *Lima) ListContainerFiles(ctx context.Context, id, path string) ([]ContainerFileEntry, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return nil, err
	}

	if !isValidContainerPath(path) {
		return nil, fmt.Errorf("invalid path")
	}

	return listContainerFiles(ctx, l.runInVM, id, path)
}

func (l *Lima) ExecContainer(ctx context.Context, id, command string) (string, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return "", err
	}

	return execInContainer(ctx, l.runInVM, id, command)
}

func (l *Lima) AttachExec(ctx context.Context, id string, stdin io.Reader, onOutput func([]byte), resizeCh <-chan ExecResize) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	shellArgs := append([]string{"shell", l.vmName, "--"}, NerdctlVMArgs(interactiveExecArgs(id)...)...)
	command := exec.CommandContext(ctx, "limactl", shellArgs...)
	return attachExecInContainer(ctx, command, stdin, onOutput, resizeCh)
}

func (l *Lima) ContainerStats(ctx context.Context, id string) (ContainerStats, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return ContainerStats{}, err
	}

	return containerStats(ctx, l.runInVM, id)
}

func (l *Lima) RestartContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return restartContainer(ctx, l.runInVM, id)
}

func (l *Lima) runInVM(ctx context.Context, command string, args ...string) ([]byte, error) {
	shellArgs := append([]string{"shell", l.vmName, "--"}, vmCommand(command, args...)...)
	return runCommand(ctx, "limactl", shellArgs...)
}

func (l *Lima) runInVMWithStdin(ctx context.Context, stdin, command string, args ...string) ([]byte, error) {
	shellArgs := append([]string{"shell", l.vmName, "--"}, vmCommand(command, args...)...)
	return runCommandWithStdin(ctx, stdin, "limactl", shellArgs...)
}

func (l *Lima) RegistryStatus(ctx context.Context) (RegistryStatus, error) {
	if err := requireRunning(ctx, l.Status); err != nil {
		return RegistryStatus{Server: defaultRegistryServer}, nil
	}

	output, err := l.runInVM(ctx, "sudo", "cat", "/root/.docker/config.json")
	if err != nil {
		return RegistryStatus{Server: defaultRegistryServer}, nil
	}

	return RegistryStatusFromConfig(output), nil
}

func (l *Lima) RegistryLogin(ctx context.Context, server, username, password string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return registryLogin(ctx, l.runInVM, l.runInVMWithStdin, server, username, password)
}

func (l *Lima) RegistryLogout(ctx context.Context, server string) error {
	if err := requireRunning(ctx, l.Status); err != nil {
		return err
	}

	return registryLogout(ctx, l.runInVM, server)
}

func vmCommand(command string, args ...string) []string {
	if command == "nerdctl" {
		return NerdctlVMArgs(args...)
	}

	return append([]string{command}, args...)
}

func limaShellEnv() []string {
	return append(os.Environ(), "SSH=ssh -o ControlMaster=no -o ControlPath=none")
}

func (l *Lima) waitForNerdctl(ctx context.Context) error {
	deadline := time.Now().Add(10 * time.Minute)
	for time.Now().Before(deadline) {
		_, err := runCommandOnce(ctx, "", "limactl", "shell", l.vmName, "--", "sudo", NerdctlBin, "info")
		if err == nil {
			return nil
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Second):
		}
	}

	return fmt.Errorf("nerdctl not ready in VM %q", l.vmName)
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

	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}

	diskGB := l.diskGB
	if diskGB <= 0 {
		diskGB = 100
	}

	content := fmt.Sprintf(limaTemplate, home, home, l.cpus, l.memoryGB, l.memorySwapGB, diskGB)
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
