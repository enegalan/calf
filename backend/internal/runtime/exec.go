package runtime

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

const defaultCommandRetries = 4
const defaultCommandRetryDelay = 200 * time.Millisecond

// runCommand executes a subprocess and returns combined stdout/stderr.
func runCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	return runCommandOnce(ctx, "", name, args...)
}

// runCommandWithStdin executes a subprocess with the given stdin payload.
func runCommandWithStdin(ctx context.Context, stdin, name string, args ...string) ([]byte, error) {
	return runCommandOnce(ctx, stdin, name, args...)
}

// runCommandWithRetry re-executes the command on transient failures with exponential backoff.
func runCommandWithRetry(ctx context.Context, retries int, delay time.Duration, stdin, name string, args ...string) ([]byte, error) {
	if retries < 0 {
		retries = 0
	}

	var lastErr error
	for attempt := 0; attempt <= retries; attempt++ {
		output, err := runCommandOnce(ctx, stdin, name, args...)
		if err == nil {
			return output, nil
		}

		lastErr = err
		if !isTransientCommandError(err) || attempt == retries {
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

// runCommandOnce runs the subprocess once without retries.
func runCommandOnce(ctx context.Context, stdin, name string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, name, args...)
	if stdin != "" {
		command.Stdin = strings.NewReader(stdin)
	}

	output, err := command.CombinedOutput()
	if err != nil {
		if formatted := formatCommandError(string(output)); formatted != "" {
			return nil, fmt.Errorf("%s", formatted)
		}

		return nil, fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}

	return output, nil
}
