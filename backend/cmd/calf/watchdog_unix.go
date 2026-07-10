//go:build !windows

package main

import (
	"context"
	"log/slog"
	"os"
	"time"
)

// watchParent shuts the daemon down when its parent dies (ppid becomes 1).
// The Flutter app spawns calf-daemon as a child; without this, orphans keep
// running after the GUI exits unexpectedly.
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
