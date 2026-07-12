package limavm

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
)

// Shell executes a command inside the named Lima VM via limactl shell.
func Shell(ctx context.Context, vmName string, args ...string) ([]byte, error) {
	return shellWithRetry(ctx, constants.DefaultCommandRetries, constants.DefaultCommandRetryDelay, vmName, args...)
}

// shellWithRetry re-executes limactl shell on transient failures with exponential backoff.
func shellWithRetry(ctx context.Context, retries int, delay time.Duration, vmName string, args ...string) ([]byte, error) {
	if retries < 0 {
		retries = 0
	}

	var lastErr error
	for attempt := 0; attempt <= retries; attempt++ {
		output, err := shellOnce(ctx, vmName, args...)
		if err == nil {
			return output, nil
		}

		lastErr = err
		if !isTransientShellError(err) || attempt == retries {
			return nil, err
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}

		if delay < 2*time.Second {
			delay *= 2
		}
	}

	return nil, lastErr
}

// shellOnce runs limactl shell once without retries.
func shellOnce(ctx context.Context, vmName string, args ...string) ([]byte, error) {
	shellArgs := append([]string{"shell", vmName, "--"}, args...)
	command := exec.CommandContext(ctx, "limactl", shellArgs...)
	command.Env = ShellEnv()

	var stdout strings.Builder
	var stderr strings.Builder
	command.Stdout = &stdout
	command.Stderr = &stderr

	if err := command.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = strings.TrimSpace(stdout.String())
		}
		return nil, fmt.Errorf("limactl %s: %w: %s", strings.Join(shellArgs, " "), err, msg)
	}

	return []byte(stdout.String()), nil
}

// isTransientShellError reports whether err from limactl shell is likely temporary and worth retrying.
func isTransientShellError(err error) bool {
	if err == nil {
		return false
	}

	message := strings.ToLower(err.Error())
	transientMarkers := []string{
		"text file busy",
		"transport is closing",
		"connection reset",
		"connection refused",
		"cannot connect to the docker daemon",
		"deadline exceeded",
		"i/o timeout",
		"broken pipe",
	}

	for _, marker := range transientMarkers {
		if strings.Contains(message, marker) {
			return true
		}
	}

	startupPathMarkers := []string{
		"no such file or directory",
		"executable file not found",
	}
	startupContexts := []string{
		"nerdctl",
		"limactl",
		"containerd",
		"docker.sock",
		"/run/containerd",
	}

	for _, marker := range startupPathMarkers {
		if !strings.Contains(message, marker) {
			continue
		}

		for _, contextMarker := range startupContexts {
			if strings.Contains(message, contextMarker) {
				return true
			}
		}
	}

	return false
}
