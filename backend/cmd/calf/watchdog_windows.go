//go:build windows

package main

import (
	"context"
	"log/slog"
	"os"
	"sync"

	"golang.org/x/sys/windows"
)

// watchParent shuts the daemon down when its parent dies. The Flutter app
// spawns calf-daemon as a child; without this, orphans keep running after
// the GUI exits unexpectedly.
// Disabled for CALF_BENCHMARK=1 so detached bench launches are not killed.
func watchParent(ctx context.Context, parentPID int, stop context.CancelFunc, logger *slog.Logger) {
	if os.Getenv("CALF_BENCHMARK") == "1" {
		return
	}
	handle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(parentPID))
	if err != nil {
		logger.Warn("could not open parent process handle, skipping parent watchdog", "error", err)
		return
	}
	defer windows.CloseHandle(handle)

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		const pollMs = 1000
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}

			result, err := windows.WaitForSingleObject(handle, pollMs)
			if err != nil {
				logger.Warn("parent process wait failed", "error", err)
				return
			}
			if result == windows.WAIT_OBJECT_0 {
				logger.Warn("parent process died, shutting down")
				stop()
				return
			}
		}
	}()

	<-ctx.Done()
	wg.Wait()
}
