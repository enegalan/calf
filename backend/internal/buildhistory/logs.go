package buildhistory

import (
	"context"
	"fmt"
	"strings"
)

// Logs fetches the build log text for a buildx history entry.
func Logs(ctx context.Context, run Runner, historyID string) (string, error) {
	historyID = strings.TrimSpace(historyID)
	if historyID == "" {
		return "", fmt.Errorf("build history logs: missing history id")
	}
	if run == nil {
		return "", fmt.Errorf("build history logs: missing docker runner")
	}

	output, err := run(ctx, "buildx", "history", "logs", historyID)
	if err != nil {
		return "", err
	}

	return string(output), nil
}
