package daemon

import (
	"context"
	"fmt"
	"time"

	"github.com/enegalan/calf/backend/internal/runtime"
)

// EnsureRuntimeRunning starts the runtime when stopped and waits until it reaches the running state.
func (s *Core) EnsureRuntimeRunning(ctx context.Context) error {
	status, err := s.Runtime.Status(ctx)
	if err != nil {
		return err
	}

	if status.State == runtime.StateRunning {
		return nil
	}

	s.Logger.Info("runtime not running; starting before registry login", "vm", status.VMName)

	startCtx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()

	if err := s.Runtime.Start(startCtx); err != nil {
		return fmt.Errorf("failed to start Calf runtime: %w", err)
	}

	deadline := time.Now().Add(3 * time.Minute)
	for time.Now().Before(deadline) {
		status, err := s.Runtime.Status(ctx)
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
