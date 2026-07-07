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
	"github.com/enegalan/calf/backend/internal/runtime"
)

func main() {
	os.Exit(run())
}

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
		runtime.ProxyConfig{
			HTTPProxy:  cfg.HTTPProxy,
			HTTPSProxy: cfg.HTTPSProxy,
			NoProxy:    cfg.NoProxy,
		},
	)
	server := api.New(cfg, logger, rt)

	if err := ensurePort(cfg.ListenAddr); err != nil {
		logger.Warn("cleaned up previous instance", "error", err)
	}

	writePidFile()
	defer removePidFile()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if os.Getppid() == 1 {
					logger.Warn("parent process died, shutting down")
					stop()
					return
				}
			}
		}
	}()

	rtCtx, rtCancel := context.WithCancel(ctx)
	defer rtCancel()

	go func() {
		logger.Info("starting runtime")
		if err := rt.Start(rtCtx); err != nil {
			logger.Warn("runtime start failed (non-fatal)", "error", err)
		} else {
			logger.Info("runtime started", "socket", rt.DockerSocket())
		}
	}()

	go server.StartBuildSync(rtCtx)
	go server.StartDockerContextManager(rtCtx)

	errCh := make(chan error, 1)
	go func() {
		errCh <- server.Run()
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
		if err := server.Shutdown(shutdownCtx); err != nil {
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

func writePidFile() {
	path := pidFilePath()
	os.MkdirAll(filepath.Dir(path), 0o755)
	os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())), 0o644)
}

func removePidFile() {
	os.Remove(pidFilePath())
}

func ensurePort(addr string) error {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return err
	}

	ln, err := net.Listen("tcp", net.JoinHostPort(host, port))
	if err == nil {
		ln.Close()
		return nil
	}

	pid, err := findPidOnPort(port)
	if err != nil || pid == 0 {
		return fmt.Errorf("port %s is in use; run: pkill -f calf", addr)
	}

	calfPID, pidErr := readPidFile()
	if pidErr != nil || calfPID != pid {
		return fmt.Errorf("port %s is in use by pid %d", addr, pid)
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
		ln, err := net.Listen("tcp", net.JoinHostPort(host, port))
		if err == nil {
			ln.Close()
			return nil
		}
	}

	return fmt.Errorf("port %s is still in use after cleanup; run: pkill -f calf", addr)
}

func findPidOnPort(port string) (int, error) {
	switch goRuntime.GOOS {
	case "windows":
		return findPidOnPortWindows(port)
	default:
		return findPidOnPortUnix(port)
	}
}

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

func findPidOnPortWindows(port string) (int, error) {
	out, err := exec.Command("netstat", "-ano").Output()
	if err != nil {
		return 0, err
	}
	target := fmt.Sprintf(":%s", port)
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.Contains(line, "LISTENING") && strings.Contains(line, target) {
			fields := strings.Fields(line)
			if len(fields) > 4 {
				pid, err := strconv.Atoi(strings.TrimSpace(fields[len(fields)-1]))
				if err == nil && pid != os.Getpid() && pid != os.Getppid() {
					return pid, nil
				}
			}
		}
	}
	return 0, errors.New("no pid found on port")
}

func pidFilePath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "calf", "calf.pid")
}

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

func inPath(dir, path string) bool {
	for _, p := range strings.Split(path, ":") {
		if p == dir {
			return true
		}
	}
	return false
}

func readPidFile() (int, error) {
	data, err := os.ReadFile(pidFilePath())
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(string(data))
}
