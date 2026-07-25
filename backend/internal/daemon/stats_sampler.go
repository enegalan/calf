package daemon

import (
	"context"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// StartStatsSampler periodically samples running container stats into the in-memory history.
func (s *Core) StartStatsSampler(ctx context.Context) {
	ticker := time.NewTicker(constants.StatsSampleInterval)
	defer ticker.Stop()

	s.sampleContainerStats(ctx)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.sampleContainerStats(ctx)
		}
	}
}

// sampleContainerStats appends one stats sample per running container and prunes deleted IDs.
func (s *Core) sampleContainerStats(ctx context.Context) {
	if s.statsHistory == nil {
		return
	}

	status, err := s.Runtime.Status(ctx)
	if err != nil || status.State != runtime.State(constants.RuntimeStateRunning) {
		return
	}

	containers, err := s.Runtime.ListContainers(ctx)
	if err != nil {
		s.Logger.Debug("stats sampler skipped list", "error", err)
		return
	}

	keep := make(map[string]struct{}, len(containers))
	now := time.Now()
	for _, container := range containers {
		id := strings.TrimSpace(container.ID)
		if id == "" {
			continue
		}
		keep[id] = struct{}{}

		if !strings.EqualFold(strings.TrimSpace(container.State), "running") {
			continue
		}

		stats, statsErr := s.Runtime.ContainerStats(ctx, id)
		if statsErr != nil {
			s.Logger.Debug("stats sampler skipped container", "id", id, "error", statsErr)
			continue
		}

		s.statsHistory.Append(id, stats, now)
	}

	s.statsHistory.RetainOnly(keep)
}

// ContainerStatsSamples returns the retained stats history for a container ID.
func (s *Core) ContainerStatsSamples(id string) []StatsSample {
	if s.statsHistory == nil {
		return nil
	}
	return s.statsHistory.Samples(id)
}

// ForgetContainerStats clears retained stats for a removed container.
func (s *Core) ForgetContainerStats(id string) {
	if s.statsHistory == nil {
		return
	}
	s.statsHistory.Forget(id)
}

// RecordContainerStats appends a sample for tests and manual seeding.
func (s *Core) RecordContainerStats(id string, stats runtime.ContainerStats, at time.Time) {
	if s.statsHistory == nil {
		return
	}
	s.statsHistory.Append(id, stats, at)
}
