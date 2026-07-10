package api

import (
	"context"
	"fmt"
	"net/http"
	goruntime "runtime"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/buildhistory"
	"github.com/enegalan/calf/backend/internal/buildstore"
	"github.com/enegalan/calf/backend/internal/runtime"
)

func (s *Server) handleBuilds(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		tagFilter := strings.TrimSpace(r.URL.Query().Get("tag"))
		s.buildsMu.RLock()
		builds := append([]runtime.Build{}, s.builds...)
		s.buildsMu.RUnlock()

		if tagFilter != "" {
			filtered := make([]runtime.Build, 0)
			for _, build := range builds {
				if build.Tag == tagFilter {
					filtered = append(filtered, build)
				}
			}
			builds = filtered
		}

		writeJSON(w, http.StatusOK, builds)
	case http.MethodPost:
		var payload struct {
			Context    string `json:"context"`
			Tag        string `json:"tag"`
			Dockerfile string `json:"dockerfile"`
			Platform   string `json:"platform"`
		}

		if err := jsonDecode(r, &payload); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		if payload.Context == "" || payload.Tag == "" {
			writeError(w, http.StatusBadRequest, "context and tag are required")
			return
		}

		platform := payload.Platform
		if platform == "" {
			platform = defaultBuildPlatform()
		}

		build := s.newBuild(payload.Context, payload.Tag, payload.Dockerfile, platform, "running")
		go s.runBuildJob(build.ID, payload.Context, payload.Tag, payload.Dockerfile, platform)
		writeJSON(w, http.StatusAccepted, build)
	default:
		methodNotAllowed(w, r)
	}
}

func (s *Server) handleBuildAction(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/v1/builds/")
	parts := strings.Split(path, "/")
	if len(parts) == 0 || parts[0] == "" {
		writeError(w, http.StatusNotFound, "build not found")
		return
	}

	buildID := parts[0]
	if len(parts) == 2 && parts[1] == "source" {
		s.handleBuildSource(w, r, buildID)
		return
	}
	if len(parts) == 2 && parts[1] == "logs" {
		s.handleBuildLogs(w, r, buildID)
		return
	}

	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	build, ok := s.getBuild(buildID)
	if !ok {
		writeError(w, http.StatusNotFound, "build not found")
		return
	}

	build = s.enrichHistoryBuildIfNeeded(r.Context(), build)

	writeJSON(w, http.StatusOK, build)
}

func (s *Server) handleBuildSource(w http.ResponseWriter, r *http.Request, buildID string) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	build, ok := s.getBuild(buildID)
	if !ok {
		writeError(w, http.StatusNotFound, "build not found")
		return
	}

	contextPath, dockerfile := s.resolveBuildSourcePaths(r.Context(), build)
	if !runtime.IsResolvableBuildContext(contextPath) {
		writeError(w, http.StatusNotFound, "Dockerfile source is not available for this build")
		return
	}

	source, err := runtime.ReadBuildSource(contextPath, dockerfile, build.Platform)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	if build.Context != contextPath || build.Dockerfile != dockerfile {
		s.updateBuildSourcePaths(buildID, contextPath, dockerfile)
	}

	writeJSON(w, http.StatusOK, source)
}

func (s *Server) handleBuildLogs(w http.ResponseWriter, r *http.Request, buildID string) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	build, ok := s.getBuild(buildID)
	if !ok {
		writeError(w, http.StatusNotFound, "build not found")
		return
	}

	build = s.enrichHistoryBuildIfNeeded(r.Context(), build)

	steps := build.Steps
	if steps == nil {
		steps = []runtime.BuildStep{}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"raw_log": build.RawLog,
		"steps":   steps,
	})
}

func (s *Server) resolveBuildSourcePaths(ctx context.Context, build runtime.Build) (string, string) {
	contextPath := build.Context
	dockerfile := build.Dockerfile
	if dockerfile == "" {
		dockerfile = "Dockerfile"
	}

	if runtime.IsResolvableBuildContext(contextPath) {
		return contextPath, dockerfile
	}

	if build.HistoryRef == "" {
		return contextPath, dockerfile
	}

	socket := s.runtime.DockerSocket()
	if socket == "" {
		return contextPath, dockerfile
	}

	detail, err := buildhistory.Inspect(ctx, socket, build.HistoryRef)
	if err != nil {
		return contextPath, dockerfile
	}

	contextPath = detail.Context
	if detail.Dockerfile != "" {
		dockerfile = detail.Dockerfile
	}

	return contextPath, dockerfile
}

func (s *Server) updateBuildSourcePaths(buildID, contextPath, dockerfile string) {
	s.buildsMu.Lock()
	defer s.buildsMu.Unlock()

	for index, build := range s.builds {
		if build.ID != buildID {
			continue
		}

		s.builds[index].Context = contextPath
		s.builds[index].Dockerfile = dockerfile
		_ = s.persistBuildsLocked()
		return
	}
}

const buildJobTimeout = 2 * time.Hour

func (s *Server) runBuildJob(buildID, contextPath, tag, dockerfile, platform string) {
	started := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), buildJobTimeout)
	defer cancel()

	result, err := s.runtime.RunBuild(ctx, contextPath, tag, dockerfile, platform)
	finishedAt := time.Now().UTC().Format(time.RFC3339)
	durationMs := time.Since(started).Milliseconds()

	revision, remote := runtime.CollectGitMetadata(contextPath)

	s.buildsMu.Lock()
	defer s.buildsMu.Unlock()

	for index, build := range s.builds {
		if build.ID != buildID {
			continue
		}

		build.FinishedAt = finishedAt
		build.DurationMs = durationMs
		build.SourceRevision = revision
		build.RemoteSource = remote
		build.Steps = result.Steps
		build.Timing = result.Timing
		build.CachedSteps = result.CachedSteps
		build.TotalSteps = result.TotalSteps
		build.Dependencies = result.Dependencies
		build.Results = result.Results
		build.Tags = result.Tags
		build.RawLog = result.RawLog

		if len(build.Dependencies) == 0 {
			build.Dependencies = []runtime.BuildDependency{}
		}
		if len(build.Results) == 0 {
			build.Results = []runtime.BuildArtifact{}
		}
		if len(build.Tags) == 0 {
			build.Tags = []runtime.BuildTag{}
		}
		if len(build.Steps) == 0 {
			build.Steps = []runtime.BuildStep{}
		}

		if err != nil {
			build.Status = "failed"
			if ctx.Err() == context.DeadlineExceeded {
				build.Error = "build timed out"
			} else if ctx.Err() == context.Canceled {
				build.Error = "build canceled"
			} else {
				build.Error = err.Error()
			}
		} else {
			build.Status = "success"
		}

		s.builds[index] = build
		_ = s.persistBuildsLocked()
		return
	}
}

func (s *Server) newBuild(contextPath, tag, dockerfile, platform, status string) runtime.Build {
	s.buildsMu.Lock()
	defer s.buildsMu.Unlock()

	s.buildSeq++
	if dockerfile == "" {
		dockerfile = "Dockerfile"
	}

	build := runtime.Build{
		ID:           fmt.Sprintf("build-%d", s.buildSeq),
		Tag:          tag,
		Context:      contextPath,
		Dockerfile:   dockerfile,
		Platform:     platform,
		Status:       status,
		CreatedAt:    time.Now().UTC().Format(time.RFC3339),
		Builder:      "default",
		Steps:        []runtime.BuildStep{},
		Dependencies: []runtime.BuildDependency{},
		Results:      []runtime.BuildArtifact{},
		Tags:         []runtime.BuildTag{},
	}
	s.builds = append([]runtime.Build{build}, s.builds...)
	_ = s.persistBuildsLocked()

	return build
}

func (s *Server) addMigratedBuild(build runtime.Build) {
	s.buildsMu.Lock()
	defer s.buildsMu.Unlock()

	s.buildSeq++
	build.ID = fmt.Sprintf("migrated-%d", s.buildSeq)
	if build.Builder == "" {
		build.Builder = "default"
	}
	if build.Steps == nil {
		build.Steps = []runtime.BuildStep{}
	}
	if build.Dependencies == nil {
		build.Dependencies = []runtime.BuildDependency{}
	}
	if build.Results == nil {
		build.Results = []runtime.BuildArtifact{}
	}
	if build.Tags == nil {
		build.Tags = []runtime.BuildTag{}
	}

	s.builds = append([]runtime.Build{build}, s.builds...)
	_ = s.persistBuildsLocked()
}

func (s *Server) enrichHistoryBuildIfNeeded(ctx context.Context, build runtime.Build) runtime.Build {
	if build.HistoryRef == "" {
		return build
	}

	needsEnrichment := !runtime.IsResolvableBuildContext(build.Context) ||
		(build.RawLog == "" && len(build.Steps) == 0) ||
		len(build.Dependencies) == 0 ||
		len(build.Results) == 0 ||
		len(build.Tags) == 0

	if !needsEnrichment {
		return build
	}

	socket := s.runtime.DockerSocket()
	if socket == "" {
		return build
	}

	enriched := s.enrichHistoryBuild(ctx, socket, build)
	if buildsEqual(build, enriched) {
		return build
	}

	s.buildsMu.Lock()
	defer s.buildsMu.Unlock()

	for index, candidate := range s.builds {
		if candidate.ID != build.ID {
			continue
		}

		merged := applyBuildEnrichment(candidate, enriched)
		if buildsEqual(merged, candidate) {
			return merged
		}

		s.builds[index] = merged
		_ = s.persistBuildsLocked()
		return merged
	}

	return enriched
}

func applyBuildEnrichment(current, enriched runtime.Build) runtime.Build {
	if enriched.Context != "" && !runtime.IsResolvableBuildContext(current.Context) {
		current.Context = enriched.Context
	}
	if enriched.Dockerfile != "" && enriched.Dockerfile != "Dockerfile" {
		if current.Dockerfile == "" || current.Dockerfile == "Dockerfile" {
			current.Dockerfile = enriched.Dockerfile
		}
	}
	if enriched.SourceRevision != "" && current.SourceRevision == "" {
		current.SourceRevision = enriched.SourceRevision
	}
	if enriched.RemoteSource != "" && current.RemoteSource == "" {
		current.RemoteSource = enriched.RemoteSource
	}
	if enriched.RawLog != "" && current.RawLog == "" {
		current.RawLog = enriched.RawLog
	}
	if len(enriched.Steps) > 0 && len(current.Steps) == 0 {
		current.Steps = enriched.Steps
	}
	if len(enriched.Dependencies) > 0 && len(current.Dependencies) == 0 {
		current.Dependencies = enriched.Dependencies
	}
	if len(enriched.Results) > 0 && len(current.Results) == 0 {
		current.Results = enriched.Results
	}
	if len(enriched.Tags) > 0 && len(current.Tags) == 0 {
		current.Tags = enriched.Tags
	}
	if enriched.Timing != (runtime.BuildTiming{}) && current.Timing == (runtime.BuildTiming{}) {
		current.Timing = enriched.Timing
	}
	if enriched.CachedSteps > 0 && current.CachedSteps == 0 {
		current.CachedSteps = enriched.CachedSteps
	}
	if enriched.TotalSteps > 0 && current.TotalSteps == 0 {
		current.TotalSteps = enriched.TotalSteps
	}
	return current
}

func (s *Server) getBuild(id string) (runtime.Build, bool) {
	s.buildsMu.RLock()
	defer s.buildsMu.RUnlock()

	for _, build := range s.builds {
		if build.ID == id {
			return build, true
		}
	}

	return runtime.Build{}, false
}

func (s *Server) persistBuildsLocked() error {
	return buildstore.Save(s.builds, s.buildSeq)
}

func (s *Server) loadBuilds() {
	file, err := buildstore.Load()
	if err != nil {
		s.logger.Warn("failed to load build history", "error", err)
		return
	}

	s.builds = file.Builds
	s.buildSeq = file.Seq
}

func defaultBuildPlatform() string {
	return fmt.Sprintf("linux/%s", goruntime.GOARCH)
}
