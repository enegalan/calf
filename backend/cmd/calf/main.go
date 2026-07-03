package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
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
	cfg, err := config.Load()
	if err != nil {
		slog.Error("failed to load config", "error", err)
		return 1
	}

	logger := config.NewLogger(cfg.LogLevel)
	rt := runtime.New(cfg.VMName, cfg.DockerSocket, cfg.CPUs, cfg.MemoryGB, cfg.MemorySwapGB, cfg.DiskGB)
	server := api.New(cfg, logger, rt)

	if err := ensurePort(cfg.ListenAddr); err != nil {
		logger.Warn("cleaned up previous instance", "error", err)
	}

	writePidFile()
	defer removePidFile()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

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
		logger.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			logger.Error("shutdown failed", "error", err)
		}
	}

	rtCancel()
	stopCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
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

	pid := findPidOnPort(port)
	if pid == 0 {
		return fmt.Errorf("port %s is in use; run: pkill -f calf", addr)
	}

	proc, _ := os.FindProcess(pid)
	if proc != nil {
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

func findPidOnPort(port string) int {
	out, err := exec.Command("lsof", "-ti", fmt.Sprintf(":%s", port), "-s", "TCP:LISTEN").Output()
	if err != nil {
		return 0
	}
	for _, raw := range strings.Fields(string(out)) {
		pid, err := strconv.Atoi(strings.TrimSpace(raw))
		if err != nil {
			continue
		}
		if pid != os.Getpid() && pid != os.Getppid() {
			return pid
		}
	}
	return 0
}

func pidFilePath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "calf", "calf.pid")
}

func readPidFile() (int, error) {
	data, err := os.ReadFile(pidFilePath())
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(string(data))
}
