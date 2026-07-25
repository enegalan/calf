package daemon

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// resourceSaver stops the engine after an idle period with no running containers.
type resourceSaver struct {
	core   *Core
	mu     sync.Mutex
	active bool
	idleAt time.Time
	stopCh chan struct{}
	doneCh chan struct{}
}

// newResourceSaver builds a Resource Saver worker for [core].
func newResourceSaver(core *Core) *resourceSaver {
	return &resourceSaver{
		core:   core,
		stopCh: make(chan struct{}),
		doneCh: make(chan struct{}),
	}
}

// Start begins the idle-watch loop until Stop.
func (r *resourceSaver) Start() {
	go r.loop()
}

// Stop ends the idle-watch loop and waits for it to exit.
func (r *resourceSaver) Stop() {
	select {
	case <-r.stopCh:
	default:
		close(r.stopCh)
	}
	<-r.doneCh
}

// Active reports whether the engine was stopped by Resource Saver.
func (r *resourceSaver) Active() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.active
}

// Clear marks Resource Saver inactive after a manual start/stop or wake.
func (r *resourceSaver) Clear() {
	r.mu.Lock()
	r.active = false
	r.idleAt = time.Time{}
	r.mu.Unlock()
}

// loop polls runtime and containers until stopCh closes.
func (r *resourceSaver) loop() {
	defer close(r.doneCh)
	ticker := time.NewTicker(constants.ResourceSaverPollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-r.stopCh:
			return
		case <-r.core.lifecycleCtx.Done():
			return
		case <-ticker.C:
			r.tick()
		}
	}
}

// tick evaluates idle time and enters Resource Saver when due.
func (r *resourceSaver) tick() {
	r.core.CfgMu.RLock()
	enabled := r.core.Cfg.ResourceSaverEnabled
	timeoutSec := r.core.Cfg.ResourceSaverTimeoutSec
	r.core.CfgMu.RUnlock()

	if !enabled {
		r.mu.Lock()
		r.idleAt = time.Time{}
		r.mu.Unlock()
		return
	}
	if timeoutSec < constants.ResourceSaverTimeoutMinSec {
		timeoutSec = constants.ResourceSaverTimeoutMinSec
	}

	ctx, cancel := context.WithTimeout(r.core.lifecycleCtx, constants.DefaultActionTimeout)
	defer cancel()

	status, statusErr := r.core.Runtime.Status(ctx)
	if statusErr != nil {
		r.core.Logger.Debug("resource saver status probe failed", "error", statusErr)
		return
	}
	if status.State != runtime.State(constants.RuntimeStateRunning) {
		r.mu.Lock()
		r.idleAt = time.Time{}
		r.mu.Unlock()
		return
	}

	containers, listErr := r.core.Runtime.ListContainers(ctx)
	if listErr != nil {
		r.core.Logger.Debug("resource saver container list failed", "error", listErr)
		return
	}
	if hasRunningContainer(containers) {
		r.mu.Lock()
		r.idleAt = time.Time{}
		r.active = false
		r.mu.Unlock()
		return
	}

	now := time.Now()
	r.mu.Lock()
	if r.idleAt.IsZero() {
		r.idleAt = now
		r.mu.Unlock()
		return
	}
	idleFor := now.Sub(r.idleAt)
	alreadyActive := r.active
	r.mu.Unlock()

	if alreadyActive || idleFor < time.Duration(timeoutSec)*time.Second {
		return
	}

	stopCtx, stopCancel := context.WithTimeout(r.core.lifecycleCtx, constants.DefaultActionTimeout)
	defer stopCancel()
	if err := r.core.Runtime.ForceStop(stopCtx); err != nil {
		r.core.Logger.Warn("resource saver failed to stop runtime", "error", err)
		return
	}

	r.mu.Lock()
	r.active = true
	r.idleAt = time.Time{}
	r.mu.Unlock()
	r.core.Logger.Info("entered resource saver mode", "idle_sec", timeoutSec)
}

// hasRunningContainer reports whether any listed container is running.
func hasRunningContainer(containers []runtime.Container) bool {
	for _, container := range containers {
		state := strings.ToLower(strings.TrimSpace(container.State))
		status := strings.ToLower(strings.TrimSpace(container.Status))
		if state == "running" || strings.HasPrefix(status, "up") {
			return true
		}
	}
	return false
}

// ResourceSaverActive reports whether Resource Saver currently holds the engine stopped.
func (s *Core) ResourceSaverActive() bool {
	if s.resourceSaver == nil {
		return false
	}
	return s.resourceSaver.Active()
}

// ClearResourceSaver clears the Resource Saver active flag after wake or manual stop.
func (s *Core) ClearResourceSaver() {
	if s.resourceSaver != nil {
		s.resourceSaver.Clear()
	}
}
