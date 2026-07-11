package daemon

import (
	"context"
	"fmt"
	"os"
	"reflect"
	"time"

	"github.com/enegalan/calf/backend/internal/buildhistory"
	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// StartBuildSync periodically imports and enriches build history from the Docker socket until ctx is canceled.
func (s *Core) StartBuildSync(ctx context.Context) {
	interval := constants.DefaultBuildSyncInterval
	s.CfgMu.RLock()
	if s.Cfg.PollIntervalMs > 0 {
		interval = time.Duration(s.Cfg.PollIntervalMs) * time.Millisecond
	}
	s.CfgMu.RUnlock()

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	s.syncBuildHistory(ctx)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.syncBuildHistory(ctx)
		}
	}
}

// syncBuildHistory imports new buildkit rows and refreshes known history-linked builds in persisted storage.
func (s *Core) syncBuildHistory(ctx context.Context) {
	socket := s.Runtime.DockerSocket()
	if socket == "" {
		return
	}

	if _, err := os.Stat(socket); err != nil {
		return
	}

	status, err := s.Runtime.Status(ctx)
	if err != nil || status.State != runtime.StateRunning {
		return
	}

	rows, err := buildhistory.List(ctx, socket)
	if err != nil {
		s.Logger.Debug("build history sync skipped", "error", err)
		return
	}

	if len(rows) == 0 {
		return
	}

	enrichCtx, cancel := context.WithTimeout(ctx, constants.BuildSyncEnrichTimeout)
	defer cancel()

	s.BuildsMu.RLock()
	known := make(map[string]struct{}, len(s.Builds))
	syncItems := make([]runtime.Build, 0)
	for _, build := range s.Builds {
		if build.HistoryRef != "" {
			known[build.HistoryRef] = struct{}{}
			syncItems = append(syncItems, build)
		}
	}
	importRows := buildhistory.MergeRows(known, rows)
	s.BuildsMu.RUnlock()

	byHistoryID := buildhistory.RowByHistoryID(rows)

	enrichedByID := make(map[string]runtime.Build, len(syncItems))
	for _, build := range syncItems {
		row, ok := byHistoryID[build.HistoryRef]
		if !ok {
			continue
		}

		updated := s.enrichHistoryBuild(enrichCtx, socket, applyHistoryRow(build, row))
		if !buildsEqual(updated, build) {
			enrichedByID[build.ID] = updated
		}
	}

	newBuilds := make([]runtime.Build, 0, len(importRows))
	for _, row := range importRows {
		newBuilds = append(newBuilds, s.enrichHistoryBuild(enrichCtx, socket, baseBuildFromHistoryRow(row)))
	}

	s.BuildsMu.Lock()
	defer s.BuildsMu.Unlock()

	changed := false

	for index, build := range s.Builds {
		updated, ok := enrichedByID[build.ID]
		if !ok {
			continue
		}

		s.Builds[index] = updated
		changed = true
	}

	if len(newBuilds) > 0 {
		for index := range newBuilds {
			s.BuildSeq++
			newBuilds[index].ID = fmt.Sprintf("history-%d", s.BuildSeq)
		}
		s.Builds = append(newBuilds, s.Builds...)
		changed = true
	}

	if changed {
		_ = s.persistBuildsLocked()
	}
}

// buildsEqual reports whether two builds have identical display-relevant fields.
func buildsEqual(left, right runtime.Build) bool {
	return left.Tag == right.Tag &&
		left.Status == right.Status &&
		left.CreatedAt == right.CreatedAt &&
		left.FinishedAt == right.FinishedAt &&
		left.DurationMs == right.DurationMs &&
		left.CachedSteps == right.CachedSteps &&
		left.TotalSteps == right.TotalSteps &&
		left.Context == right.Context &&
		left.Dockerfile == right.Dockerfile &&
		reflect.DeepEqual(left.Steps, right.Steps) &&
		left.RawLog == right.RawLog &&
		reflect.DeepEqual(left.Dependencies, right.Dependencies) &&
		reflect.DeepEqual(left.Results, right.Results) &&
		reflect.DeepEqual(left.Tags, right.Tags) &&
		timingEqual(left.Timing, right.Timing)
}

// timingEqual reports whether two BuildTiming values are identical.
func timingEqual(left, right runtime.BuildTiming) bool {
	return left.ImagePullsMs == right.ImagePullsMs &&
		left.LocalTransfersMs == right.LocalTransfersMs &&
		left.ExecutionsMs == right.ExecutionsMs &&
		left.FileOperationsMs == right.FileOperationsMs &&
		left.ResultExportsMs == right.ResultExportsMs &&
		left.IdleMs == right.IdleMs
}

// enrichHistoryBuild fills context, logs, and artifacts for a build linked to buildkit history.
func (s *Core) enrichHistoryBuild(ctx context.Context, socket string, build runtime.Build) runtime.Build {
	if build.HistoryRef == "" {
		return build
	}

	if !runtime.IsResolvableBuildContext(build.Context) {
		detail, err := buildhistory.Inspect(ctx, socket, build.HistoryRef)
		if err == nil {
			build.Context = detail.Context
			if detail.Dockerfile != "" {
				build.Dockerfile = runtime.NormalizeDockerfilePath(detail.Context, detail.Dockerfile)
			}

			if revision, remote := runtime.CollectGitMetadata(build.Context); revision != "" || remote != "" {
				build.SourceRevision = revision
				build.RemoteSource = remote
			}
		}
	}

	if isTerminalBuildStatus(build.Status) && build.RawLog == "" && len(build.Steps) == 0 {
		logs, err := buildhistory.Logs(ctx, socket, build.HistoryRef)
		if err == nil {
			runtime.ApplyBuildLogs(&build, logs)
		}
	}

	runtime.EnrichSyncedBuild(ctx, socket, &build)

	if artifacts, err := buildhistory.BuildArtifacts(ctx, socket, build.HistoryRef, build.Platform); err == nil && len(artifacts) > 0 {
		build.Results = artifacts
	}

	return build
}

// isTerminalBuildStatus reports whether a build status indicates the build has finished.
func isTerminalBuildStatus(status string) bool {
	switch status {
	case "success", "failed":
		return true
	default:
		return false
	}
}

// baseBuildFromHistoryRow constructs a runtime.Build skeleton from a buildkit history row.
func baseBuildFromHistoryRow(row buildhistory.Row) runtime.Build {
	createdAt := row.BuildCreatedAt()
	if createdAt == "" {
		createdAt = time.Now().UTC().Format(time.RFC3339)
	}

	return runtime.Build{
		HistoryRef:   row.HistoryID(),
		Tag:          buildhistory.NormalizeTag(row.BuildName()),
		Context:      "",
		Dockerfile:   "Dockerfile",
		Platform:     DefaultBuildPlatform(),
		Status:       buildhistory.NormalizeStatus(row.BuildStatus()),
		CreatedAt:    createdAt,
		FinishedAt:   row.CompletedAt,
		DurationMs:   row.BuildDurationMs(),
		Builder:      "default",
		CachedSteps:  row.CachedSteps,
		TotalSteps:   row.TotalSteps,
		Steps:        []runtime.BuildStep{},
		Dependencies: []runtime.BuildDependency{},
		Results:      []runtime.BuildArtifact{},
		Tags:         []runtime.BuildTag{},
	}
}

// applyHistoryRow updates mutable build fields from a fresh buildkit history row.
func applyHistoryRow(build runtime.Build, row buildhistory.Row) runtime.Build {
	updated := build
	updated.Tag = buildhistory.NormalizeTag(row.BuildName())
	updated.Status = buildhistory.NormalizeStatus(row.BuildStatus())
	if createdAt := row.BuildCreatedAt(); createdAt != "" {
		updated.CreatedAt = createdAt
	}
	if row.CompletedAt != "" {
		updated.FinishedAt = row.CompletedAt
	}
	if durationMs := row.BuildDurationMs(); durationMs > 0 {
		updated.DurationMs = durationMs
	}
	if row.CachedSteps > 0 {
		updated.CachedSteps = row.CachedSteps
	}
	if row.TotalSteps > 0 {
		updated.TotalSteps = row.TotalSteps
	}
	return updated
}
