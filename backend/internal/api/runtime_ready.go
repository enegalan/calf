package api

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/enegalan/calf/backend/internal/runtime"
)

// ensureRuntimeRunning starts the runtime when stopped and waits until it reaches the running state.
func (s *Server) ensureRuntimeRunning(ctx context.Context) error {
	status, err := s.runtime.Status(ctx)
	if err != nil {
		return err
	}

	if status.State == runtime.StateRunning {
		return nil
	}

	s.logger.Info("runtime not running; starting before registry login", "vm", status.VMName)

	startCtx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()

	if err := s.runtime.Start(startCtx); err != nil {
		return fmt.Errorf("failed to start Calf runtime: %w", err)
	}

	deadline := time.Now().Add(3 * time.Minute)
	for time.Now().Before(deadline) {
		status, err := s.runtime.Status(ctx)
		if err != nil {
			return err
		}

		if status.State == runtime.StateRunning {
			return nil
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}

	return fmt.Errorf("Calf runtime did not start in time")
}

// ensureRuntimeOrFail ensures the runtime is running and writes an error response on failure.
func (s *Server) ensureRuntimeOrFail(w http.ResponseWriter, ctx context.Context) bool {
	if err := s.ensureRuntimeRunning(ctx); err != nil {
		if writeRuntimeError(w, err) {
			return false
		}

		writeError(w, http.StatusServiceUnavailable, err.Error())
		return false
	}

	return true
}
