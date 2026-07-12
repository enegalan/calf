package dockerexec

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// Run executes docker against the given unix socket using ctx for cancellation.
func Run(ctx context.Context, socket string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, "docker", args...)
	command.Env = append(os.Environ(), "DOCKER_HOST=unix://"+socket)
	output, err := command.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("docker %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}

	return output, nil
}

// RunError runs docker and discards output, returning only the error.
func RunError(ctx context.Context, socket string, args ...string) error {
	_, err := Run(ctx, socket, args...)
	return err
}
