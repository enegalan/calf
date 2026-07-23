package daemon

import (
	"context"
	"fmt"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// EnsureRuntimeRunning starts the runtime when needed and waits until it reaches the running state.
// Start is idempotent: when the VM is already up but the host socket was torn down (keep-alive quit
// within the same process, or a raced first Start), this restores host setup.
// Concurrent callers share one Start via runtimeStartMu (main async boot vs HTTP).
func (s *Core) EnsureRuntimeRunning(ctx context.Context) error {
	s.runtimeStartMu.Lock()
	defer s.runtimeStartMu.Unlock()

	startCtx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()

	status, statusErr := s.Runtime.Status(ctx)
	if statusErr != nil {
		return fmt.Errorf("Runtime.Status: %w", statusErr)
	}
	if status.State != runtime.State(constants.RuntimeStateRunning) {
		s.Logger.Info("runtime not running; starting", "vm", status.VMName)
	}

	if err := s.Runtime.Start(startCtx); err != nil {
		return fmt.Errorf("failed to start Calf runtime: %w", err)
	}

	deadline := time.Now().Add(3 * time.Minute)
	for time.Now().Before(deadline) {
		status, err := s.Runtime.Status(ctx)
		if err != nil {
			return fmt.Errorf("Runtime.Status: %w", err)
		}

		if status.State == runtime.State(constants.RuntimeStateRunning) {
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
