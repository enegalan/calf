package runtime

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

func runCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	return runCommandWithStdin(ctx, "", name, args...)
}

func runCommandWithStdin(ctx context.Context, stdin, name string, args ...string) ([]byte, error) {
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
