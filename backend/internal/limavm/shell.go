package limavm

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

// Shell executes a command inside the named Lima VM via limactl shell.
func Shell(ctx context.Context, vmName string, args ...string) ([]byte, error) {
	shellArgs := append([]string{"shell", vmName, "--"}, args...)
	command := exec.CommandContext(ctx, "limactl", shellArgs...)

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
