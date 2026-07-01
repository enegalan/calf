package cli

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/enegalan/calf/backend/internal/api"
	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/runtime"
)

func Run(args []string) int {
	if len(args) == 0 {
		return runDaemon()
	}

	switch args[0] {
	case "start":
		return startCommand()
	case "stop":
		return stopCommand()
	case "status":
		return statusCommand()
	case "serve":
		return runDaemon()
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", args[0])
		return printUsage()
	}
}

func printUsage() int {
	fmt.Fprint(os.Stderr, `Usage:
  calf            Run the API daemon
  calf serve      Run the API daemon
  calf start      Start runtime, daemon, and Docker socket
  calf stop       Stop daemon and runtime
  calf status     Show daemon and runtime status
`)
	return 1
}

func startCommand() int {
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to load config: %v\n", err)
		return 1
	}

	rt := runtime.New(cfg.VMName, cfg.DockerSocket)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	if err := rt.Start(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "failed to start runtime: %v\n", err)
		return 1
	}

	if running, _ := daemonRunning(); running {
		fmt.Println("daemon already running")
	} else if err := startDaemonBackground(); err != nil {
		fmt.Fprintf(os.Stderr, "failed to start daemon: %v\n", err)
		return 1
	}

	fmt.Printf("Calf is running\n")
	fmt.Printf("Docker socket: %s\n", rt.DockerSocket())
	fmt.Printf("Set DOCKER_HOST=unix://%s\n", rt.DockerSocket())
	return 0
}

func stopCommand() int {
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to load config: %v\n", err)
		return 1
	}

	if err := stopDaemon(); err != nil {
		fmt.Fprintf(os.Stderr, "failed to stop daemon: %v\n", err)
		return 1
	}

	rt := runtime.New(cfg.VMName, cfg.DockerSocket)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	if err := rt.Stop(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "failed to stop runtime: %v\n", err)
		return 1
	}

	fmt.Println("Calf stopped")
	return 0
}

func statusCommand() int {
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to load config: %v\n", err)
		return 1
	}

	rt := runtime.New(cfg.VMName, cfg.DockerSocket)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	runtimeStatus, err := rt.Status(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "runtime status error: %v\n", err)
		return 1
	}

	fmt.Printf("Runtime mode: %s\n", runtimeStatus.Mode)
	fmt.Printf("Runtime state: %s\n", runtimeStatus.State)
	fmt.Printf("Docker socket: %s\n", runtimeStatus.DockerSocket)
	if runtimeStatus.VMName != "" {
		fmt.Printf("VM name: %s\n", runtimeStatus.VMName)
	}

	if running, pid := daemonRunning(); running {
		fmt.Printf("Daemon: running (pid %d)\n", pid)
	} else {
		fmt.Println("Daemon: stopped")
	}

	return 0
}

func runDaemon() int {
	cfg, err := config.Load()
	if err != nil {
		slog.Error("failed to load config", "error", err)
		return 1
	}

	logger := config.NewLogger(cfg.LogLevel)
	rt := runtime.New(cfg.VMName, cfg.DockerSocket)
	server := api.New(cfg, logger, rt)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		errCh <- server.Run()
	}()

	select {
	case err := <-errCh:
		if err != nil {
			logger.Error("server stopped", "error", err)
			return 1
		}
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			logger.Error("shutdown failed", "error", err)
			return 1
		}
	}

	return 0
}

func pidFilePath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(home, ".config", "calf", "calf.pid"), nil
}

func daemonRunning() (bool, int) {
	path, err := pidFilePath()
	if err != nil {
		return false, 0
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return false, 0
	}

	pid, err := strconv.Atoi(string(data))
	if err != nil {
		return false, 0
	}

	process, err := os.FindProcess(pid)
	if err != nil {
		return false, 0
	}

	if err := process.Signal(syscall.Signal(0)); err != nil {
		return false, 0
	}

	return true, pid
}

func startDaemonBackground() error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}

	command := exec.Command(executable, "serve")
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr

	if err := command.Start(); err != nil {
		return err
	}

	path, err := pidFilePath()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	return os.WriteFile(path, []byte(strconv.Itoa(command.Process.Pid)), 0o644)
}

func stopDaemon() error {
	running, pid := daemonRunning()
	if !running {
		return nil
	}

	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}

	if err := process.Signal(syscall.SIGTERM); err != nil {
		return err
	}

	path, err := pidFilePath()
	if err != nil {
		return err
	}

	return os.Remove(path)
}
