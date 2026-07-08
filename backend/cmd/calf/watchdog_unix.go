//go:build !windows

package main

import (
	"context"
	"log/slog"
	"os"
	"time"
)

func watchParent(ctx context.Context, _ int, stop context.CancelFunc, logger *slog.Logger) {
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
}
