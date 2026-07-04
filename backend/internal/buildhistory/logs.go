package buildhistory

import (
	"context"
	"fmt"
	"strings"
)

func Logs(ctx context.Context, socket, historyID string) (string, error) {
	historyID = strings.TrimSpace(historyID)
	if historyID == "" {
		return "", fmt.Errorf("build history logs: missing history id")
	}

	output, err := runDocker(ctx, socket, "buildx", "history", "logs", historyID)
	if err != nil {
		return "", err
	}

	return string(output), nil
}
