package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	goRuntime "runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/enegalan/calf/backend/internal/api"
	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/middleware"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// main delegates to run and maps its exit code to the process status.
func main() {
	os.Exit(run())
}

// run loads config, starts the HTTP server and container runtime, and shuts
// both down cleanly on SIGINT/SIGTERM or when the parent process dies.
func run() int {
	os.Setenv("PATH", ensurePath())

	cfg, err := config.Load()
	if err != nil {
		slog.Error("failed to load config", "error", err)
		return 1
	}

	logger := config.NewLogger(cfg.LogLevel)
	rt := runtime.New(
		cfg.VMName,
		cfg.DockerSocket,
		cfg.CPUs,
		cfg.MemoryGB,
		cfg.MemorySwapGB,
		cfg.DiskGB,
		runtime.ParseListenPort(cfg.ListenAddr),
		cfg.VMKeepAlive,
		cfg.Rootless,
		runtime.ProxyConfig{
			HTTPProxy:  cfg.HTTPProxy,
			HTTPSProxy: cfg.HTTPSProxy,
			NoProxy:    cfg.NoProxy,
		},
	)
	gateway := api.New(cfg, logger, rt).WithMiddleware(
		middleware.CORS(),
		middleware.Recovery(logger),
		middleware.Logging(logger),
	)

	if err := ensurePort(cfg.ListenAddr); err != nil {
		logger.Error("listen port unavailable", "error", err)
		return 1
	}

	writePidFile()
	defer removePidFile()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go watchParent(ctx, os.Getppid(), stop, logger)

	rtCtx, rtCancel := context.WithCancel(ctx)
	defer rtCancel()

	// Runtime starts in the background so the HTTP API is available immediately
	// (handlers return 503 until the VM/containerd stack is ready).
	go func() {
		logger.Info("starting runtime")
		if err := rt.Start(rtCtx); err != nil {
			if rtCtx.Err() != nil {
				return
			}
			logger.Warn("runtime start failed (non-fatal)", "error", err)
		} else {
			logger.Info("runtime started", "socket", rt.DockerSocket())
		}
	}()

	go gateway.Backend().StartBuildSync(rtCtx)
	go gateway.Backend().DockerCLI.Start(rtCtx)

	errCh := make(chan error, 1)
	go func() {
		errCh <- gateway.Run()
	}()

	select {
	case err := <-errCh:
		if err != nil {
			logger.Error("server stopped", "error", err)
			rtCancel()
			stopCtx, stopCancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer stopCancel()
			if stopErr := rt.Stop(stopCtx); stopErr != nil {
				logger.Error("runtime stop failed", "error", stopErr)
			}
			return 1
		}
	case <-ctx.Done():
		logger.Info("shutting down")
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()
		if err := gateway.Shutdown(shutdownCtx); err != nil {
			logger.Error("shutdown failed", "error", err)
		}
	}

	rtCancel()
	stopCtx, stopCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer stopCancel()
	if err := rt.Stop(stopCtx); err != nil {
		logger.Error("runtime stop failed", "error", err)
	}

	return 0
}

// writePidFile records the current process ID so a later instance can reclaim the listen port.
func writePidFile() {
	path := pidFilePath()
	os.MkdirAll(filepath.Dir(path), 0o755)
	os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())), 0o644)
}

// removePidFile deletes the PID file on shutdown so stale ownership is not assumed.
func removePidFile() {
	os.Remove(pidFilePath())
}

// ensurePort frees the listen address when a previous calf instance left it
// occupied. Reclaims the port when the listener is calf-daemon or matches calf.pid.
func ensurePort(addr string) error {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return err
	}

	if portAvailable(host, port) {
		return nil
	}

	pid, err := findPidOnPort(port)
	if err != nil || pid == 0 {
		return fmt.Errorf("port %s is in use; close the Calf app or stop the other process", addr)
	}

	calfPID, pidErr := readPidFile()
	canReclaim := pidErr == nil && calfPID == pid
	if !canReclaim && !isCalfListener(pid) {
		return fmt.Errorf("port %s is in use by pid %d; close the Calf app or stop that process", addr, pid)
	}

	proc, err := os.FindProcess(pid)
	if err != nil {
		return fmt.Errorf("port %s is in use by pid %d, but process not found", addr, pid)
	}

	if goRuntime.GOOS == "windows" {
		proc.Kill()
	} else {
		proc.Signal(syscall.SIGTERM)
	}

	for i := 0; i < 10; i++ {
		time.Sleep(300 * time.Millisecond)
		if portAvailable(host, port) {
			return nil
		}
	}

	return fmt.Errorf("port %s is still in use after cleanup; close the Calf app and retry", addr)
}

// portAvailable reports whether the TCP listen address can be bound right now.
func portAvailable(host, port string) bool {
	ln, err := net.Listen("tcp", net.JoinHostPort(host, port))
	if err != nil {
		return false
	}
	ln.Close()
	return true
}

// isCalfListener reports whether pid is a previous calf or calf-daemon instance.
func isCalfListener(pid int) bool {
	switch goRuntime.GOOS {
	case "windows":
		return isCalfListenerWindows(pid)
	default:
		return isCalfListenerUnix(pid)
	}
}

// isCalfListenerUnix checks the process command line on Unix-like systems.
func isCalfListenerUnix(pid int) bool {
	out, err := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "args=").Output()
	if err != nil {
		return false
	}
	return looksLikeCalfProcess(string(out))
}

// isCalfListenerWindows checks the process image name on Windows.
func isCalfListenerWindows(pid int) bool {
	out, err := exec.Command("tasklist", "/FI", fmt.Sprintf("PID eq %d", pid), "/FO", "CSV", "/NH").Output()
	if err != nil {
		return false
	}
	return looksLikeCalfProcess(string(out))
}

// looksLikeCalfProcess reports whether a ps/tasklist line refers to calf-daemon or go run ./cmd/calf.
func looksLikeCalfProcess(command string) bool {
	lower := strings.ToLower(strings.TrimSpace(command))
	return strings.Contains(lower, "calf-daemon") ||
		strings.Contains(lower, "cmd/calf") ||
		strings.Contains(lower, `cmd\calf`)
}

// findPidOnPort returns the PID listening on port, excluding this process and its parent.
func findPidOnPort(port string) (int, error) {
	switch goRuntime.GOOS {
	case "windows":
		return findPidOnPortWindows(port)
	default:
		return findPidOnPortUnix(port)
	}
}

// findPidOnPortUnix uses lsof to find the listener PID on Unix-like systems.
func findPidOnPortUnix(port string) (int, error) {
	out, err := exec.Command("lsof", "-ti", fmt.Sprintf(":%s", port), "-s", "TCP:LISTEN").Output()
	if err != nil {
		return 0, err
	}
	for _, raw := range strings.Fields(string(out)) {
		pid, err := strconv.Atoi(strings.TrimSpace(raw))
		if err != nil {
			continue
		}
		if pid != os.Getpid() && pid != os.Getppid() {
			return pid, nil
		}
	}
	return 0, errors.New("no pid found on port")
}

// findPidOnPortWindows uses netstat to find the listener PID on Windows.
func findPidOnPortWindows(port string) (int, error) {
	out, err := exec.Command("netstat", "-ano").Output()
	if err != nil {
		return 0, err
	}
	target := fmt.Sprintf(":%s", port)
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		fields := strings.Fields(line)
		if len(fields) < 5 || fields[3] != "LISTENING" {
			continue
		}
		if strings.HasSuffix(fields[1], target) {
			pid, err := strconv.Atoi(strings.TrimSpace(fields[len(fields)-1]))
			if err == nil && pid != os.Getpid() && pid != os.Getppid() {
				return pid, nil
			}
		}
	}
	return 0, errors.New("no pid found on port")
}

// pidFilePath returns the path to ~/.config/calf/calf.pid.
func pidFilePath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "calf", "calf.pid")
}

// ensurePath prepends Homebrew bin dirs when limactl lives there. The GUI
// subprocess often inherits a minimal PATH that omits /opt/homebrew/bin.
func ensurePath() string {
	existing := os.Getenv("PATH")
	if goRuntime.GOOS == "windows" {
		return existing
	}

	needed := false
	for _, dir := range []string{"/opt/homebrew/bin", "/usr/local/bin"} {
		if _, err := os.Stat(filepath.Join(dir, "limactl")); err == nil && !inPath(dir, existing) {
			existing = dir + ":" + existing
			needed = true
		}
	}
	if !needed {
		for _, dir := range []string{"/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"} {
			if !inPath(dir, existing) {
				existing = dir + ":" + existing
			}
		}
	}
	return existing
}

// inPath reports whether dir appears as a colon-separated entry in path.
func inPath(dir, path string) bool {
	for _, p := range strings.Split(path, ":") {
		if p == dir {
			return true
		}
	}
	return false
}

// readPidFile reads the PID written by a previous calf instance.
func readPidFile() (int, error) {
	data, err := os.ReadFile(pidFilePath())
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(string(data))
}
