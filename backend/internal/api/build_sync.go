package api

import (
	"context"
	"fmt"
	"os"
	"reflect"
	"time"

	"github.com/enegalan/calf/backend/internal/buildhistory"
	"github.com/enegalan/calf/backend/internal/runtime"
)

const buildSyncInterval = 30 * time.Second
const buildSyncEnrichTimeout = 2 * time.Minute

func (s *Server) StartBuildSync(ctx context.Context) {
	interval := buildSyncInterval
	s.cfgMu.RLock()
	if s.cfg.PollIntervalMs > 0 {
		interval = time.Duration(s.cfg.PollIntervalMs) * time.Millisecond
	}
	s.cfgMu.RUnlock()

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

func (s *Server) syncBuildHistory(ctx context.Context) {
	socket := s.runtime.DockerSocket()
	if socket == "" {
		return
	}

	if _, err := os.Stat(socket); err != nil {
		return
	}

	status, err := s.runtime.Status(ctx)
	if err != nil || status.State != runtime.StateRunning {
		return
	}

	rows, err := buildhistory.List(ctx, socket)
	if err != nil {
		s.logger.Debug("build history sync skipped", "error", err)
		return
	}

	if len(rows) == 0 {
		return
	}

	enrichCtx, cancel := context.WithTimeout(ctx, buildSyncEnrichTimeout)
	defer cancel()

	s.buildsMu.RLock()
	known := make(map[string]struct{}, len(s.builds))
	syncItems := make([]runtime.Build, 0)
	for _, build := range s.builds {
		if build.HistoryRef != "" {
			known[build.HistoryRef] = struct{}{}
			syncItems = append(syncItems, build)
		}
	}
	importRows := buildhistory.MergeRows(known, rows)
	s.buildsMu.RUnlock()

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

	s.buildsMu.Lock()
	defer s.buildsMu.Unlock()

	changed := false

	for index, build := range s.builds {
		updated, ok := enrichedByID[build.ID]
		if !ok {
			continue
		}

		s.builds[index] = updated
		changed = true
	}

	if len(newBuilds) > 0 {
		for index := range newBuilds {
			s.buildSeq++
			newBuilds[index].ID = fmt.Sprintf("history-%d", s.buildSeq)
		}
		s.builds = append(newBuilds, s.builds...)
		changed = true
	}

	if changed {
		_ = s.persistBuildsLocked()
	}
}

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

func timingEqual(left, right runtime.BuildTiming) bool {
	return left.ImagePullsMs == right.ImagePullsMs &&
		left.LocalTransfersMs == right.LocalTransfersMs &&
		left.ExecutionsMs == right.ExecutionsMs &&
		left.FileOperationsMs == right.FileOperationsMs &&
		left.ResultExportsMs == right.ResultExportsMs &&
		left.IdleMs == right.IdleMs
}

func (s *Server) enrichHistoryBuild(ctx context.Context, socket string, build runtime.Build) runtime.Build {
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

func isTerminalBuildStatus(status string) bool {
	switch status {
	case "success", "failed":
		return true
	default:
		return false
	}
}

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
		Platform:     defaultBuildPlatform(),
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
