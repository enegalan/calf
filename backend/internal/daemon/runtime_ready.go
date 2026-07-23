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
// Concurrent callers share one Start; each caller returns promptly if its ctx is canceled.
func (s *Core) EnsureRuntimeRunning(ctx context.Context) error {
	s.runtimeStartMu.Lock()
	if inflight := s.runtimeStartInflight; inflight != nil {
		s.runtimeStartMu.Unlock()
		return waitRuntimeStart(ctx, inflight)
	}
	inflight := &runtimeStartResult{done: make(chan struct{})}
	s.runtimeStartInflight = inflight
	s.runtimeStartMu.Unlock()

	go func() {
		err := s.startRuntimeUntilRunning()
		s.runtimeStartMu.Lock()
		inflight.err = err
		s.runtimeStartInflight = nil
		close(inflight.done)
		s.runtimeStartMu.Unlock()
	}()

	return waitRuntimeStart(ctx, inflight)
}

// waitRuntimeStart returns when the shared start finishes or ctx is canceled.
func waitRuntimeStart(ctx context.Context, inflight *runtimeStartResult) error {
	select {
	case <-inflight.done:
		return inflight.err
	case <-ctx.Done():
		return ctx.Err()
	}
}

// startRuntimeUntilRunning runs Start and polls until running or the shared start deadline.
func (s *Core) startRuntimeUntilRunning() error {
	parent := context.Background()
	if s.lifecycleCtx != nil {
		parent = s.lifecycleCtx
	}
	startCtx, cancel := context.WithTimeout(parent, 3*time.Minute)
	defer cancel()

	status, statusErr := s.Runtime.Status(startCtx)
	if statusErr != nil {
		return fmt.Errorf("Runtime.Status: %w", statusErr)
	}
	if status.State != runtime.State(constants.RuntimeStateRunning) {
		s.Logger.Info("runtime not running; starting", "vm", status.VMName)
	}

	if err := s.Runtime.Start(startCtx); err != nil {
		return fmt.Errorf("failed to start Calf runtime: %w", err)
	}

	for {
		status, err := s.Runtime.Status(startCtx)
		if err != nil {
			return fmt.Errorf("Runtime.Status: %w", err)
		}
		if status.State == runtime.State(constants.RuntimeStateRunning) {
			return nil
		}
		select {
		case <-startCtx.Done():
			if startCtx.Err() == context.DeadlineExceeded {
				return fmt.Errorf("Calf runtime did not start in time")
			}
			return startCtx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}
