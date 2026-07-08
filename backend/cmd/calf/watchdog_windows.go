//go:build windows

package main

import (
	"context"
	"log/slog"

	"golang.org/x/sys/windows"
)

func watchParent(ctx context.Context, parentPID int, stop context.CancelFunc, logger *slog.Logger) {
	handle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(parentPID))
	if err != nil {
		logger.Warn("could not open parent process handle, skipping parent watchdog", "error", err)
		return
	}
	defer windows.CloseHandle(handle)

	go func() {
		_, err := windows.WaitForSingleObject(handle, windows.INFINITE)
		if err != nil {
			logger.Warn("parent process wait failed", "error", err)
			return
		}
		logger.Warn("parent process died, shutting down")
		stop()
	}()

	<-ctx.Done()
}
