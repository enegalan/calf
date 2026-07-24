package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	goruntime "runtime"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/buildhistory"
	"github.com/enegalan/calf/backend/internal/buildstore"
	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/dockerexec"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// resolveBuildSourcePaths returns the build context and Dockerfile path, falling back to buildkit history when needed.
func (s *Core) ResolveBuildSourcePaths(ctx context.Context, build runtime.Build) (string, string) {
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

	socket := s.Runtime.DockerSocket()
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

// updateBuildSourcePaths persists resolved context and Dockerfile paths for a build record.
func (s *Core) UpdateBuildSourcePaths(buildID, contextPath, dockerfile string) {
	s.BuildsMu.Lock()
	defer s.BuildsMu.Unlock()

	for index, build := range s.Builds {
		if build.ID != buildID {
			continue
		}

		s.Builds[index].Context = contextPath
		s.Builds[index].Dockerfile = dockerfile
		_ = s.persistBuildsLocked()
		return
	}
}

// RunBuildJob executes a build in the background and updates the in-memory build record on completion.
func (s *Core) RunBuildJob(buildID, contextPath, tag, dockerfile, platform string) {
	started := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), constants.BuildJobTimeout)
	defer cancel()

	result, err := s.Runtime.RunBuild(ctx, contextPath, tag, dockerfile, platform)
	finishedAt := time.Now().UTC().Format(time.RFC3339)
	durationMs := time.Since(started).Milliseconds()

	revision, remote := runtime.CollectGitMetadata(contextPath)

	s.BuildsMu.Lock()
	defer s.BuildsMu.Unlock()

	for index, build := range s.Builds {
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

		s.Builds[index] = build
		_ = s.persistBuildsLocked()
		return
	}
}

// newBuild creates a build record, appends it to history, persists it, and returns the new entry.
func (s *Core) NewBuild(contextPath, tag, dockerfile, platform, status string) runtime.Build {
	s.BuildsMu.Lock()
	defer s.BuildsMu.Unlock()

	s.BuildSeq++
	if dockerfile == "" {
		dockerfile = "Dockerfile"
	}

	build := runtime.Build{
		ID:           fmt.Sprintf("build-%d", s.BuildSeq),
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
	s.Builds = append([]runtime.Build{build}, s.Builds...)
	_ = s.persistBuildsLocked()

	return build
}

// addMigratedBuild appends a build imported from Docker Desktop migration to persisted history.
func (s *Core) AddMigratedBuild(build runtime.Build) {
	s.BuildsMu.Lock()
	defer s.BuildsMu.Unlock()

	s.BuildSeq++
	build.ID = fmt.Sprintf("migrated-%d", s.BuildSeq)
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

	s.Builds = append([]runtime.Build{build}, s.Builds...)
	_ = s.persistBuildsLocked()
}

// enrichHistoryBuildIfNeeded fills missing build fields from buildkit history and persists changes when found.
func (s *Core) EnrichHistoryBuildIfNeeded(ctx context.Context, build runtime.Build) runtime.Build {
	if build.HistoryRef == "" {
		return build
	}

	needsEnrichment := !runtime.IsResolvableBuildContext(build.Context) ||
		(build.RawLog == "" && len(build.Steps) == 0) ||
		len(build.Dependencies) == 0 ||
		dependenciesNeedDigest(build.Dependencies) ||
		len(build.Results) == 0 ||
		len(build.Tags) == 0

	if !needsEnrichment {
		return build
	}

	socket := s.Runtime.DockerSocket()
	if socket == "" {
		return build
	}

	enriched := s.enrichHistoryBuild(ctx, socket, build)
	if buildsEqual(build, enriched) {
		return build
	}

	s.BuildsMu.Lock()
	defer s.BuildsMu.Unlock()

	for index, candidate := range s.Builds {
		if candidate.ID != build.ID {
			continue
		}

		merged := applyBuildEnrichment(candidate, enriched)
		if buildsEqual(merged, candidate) {
			return merged
		}

		s.Builds[index] = merged
		_ = s.persistBuildsLocked()
		return merged
	}

	return enriched
}

// DownloadBuildArtifact returns JSON bytes for a build result digest and a suggested file name.
func (s *Core) DownloadBuildArtifact(ctx context.Context, buildID, digest string) ([]byte, string, error) {
	digest = strings.TrimSpace(digest)
	if digest == "" {
		return nil, "", fmt.Errorf("digest is required")
	}

	build, ok := s.GetBuild(buildID)
	if !ok {
		return nil, "", fmt.Errorf("build not found")
	}

	build = s.EnrichHistoryBuildIfNeeded(ctx, build)

	var matched runtime.BuildArtifact
	for _, artifact := range build.Results {
		if artifact.Digest == digest {
			matched = artifact
			break
		}
	}
	if matched.Digest == "" {
		return nil, "", fmt.Errorf("build result not found")
	}

	fileName := artifactDownloadFileName(digest)
	socket := s.Runtime.DockerSocket()

	if build.HistoryRef != "" && socket != "" {
		body, err := buildhistory.FetchArtifactBytes(ctx, socket, build.HistoryRef, digest)
		if err == nil && len(body) > 0 {
			return body, fileName, nil
		}
		s.Logger.Debug(
			"build artifact attachment fetch failed",
			"build", buildID,
			"digest", digest,
			"error", err,
		)
	}

	if socket != "" && build.Tag != "" {
		output, err := dockerexec.Run(ctx, socket, "image", "inspect", build.Tag)
		if err == nil && len(output) > 0 {
			return output, fileName, nil
		}
	}

	payload, err := json.MarshalIndent(matched, "", "  ")
	if err != nil {
		return nil, "", fmt.Errorf("encode artifact metadata: %w", err)
	}
	return payload, fileName, nil
}

// artifactDownloadFileName builds sha256_<hash>.json from an OCI digest.
func artifactDownloadFileName(digest string) string {
	hash := strings.TrimPrefix(digest, "sha256:")
	if hash == "" {
		hash = "artifact"
	}
	return "sha256_" + hash + ".json"
}

// dependenciesNeedDigest reports whether any dependency is missing a digest.
func dependenciesNeedDigest(dependencies []runtime.BuildDependency) bool {
	for _, dependency := range dependencies {
		if strings.TrimSpace(dependency.Digest) == "" {
			return true
		}
	}
	return false
}

// applyBuildEnrichment merges enriched fields into current without overwriting already-populated values.
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
	if len(enriched.Dependencies) > 0 &&
		(len(current.Dependencies) == 0 || dependenciesNeedDigest(current.Dependencies)) {
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

// getBuild returns the build with the given ID from in-memory history.
func (s *Core) GetBuild(id string) (runtime.Build, bool) {
	s.BuildsMu.RLock()
	defer s.BuildsMu.RUnlock()

	for _, build := range s.Builds {
		if build.ID == id {
			return build, true
		}
	}

	return runtime.Build{}, false
}

// persistBuildsLocked saves the current build list and sequence counter; caller must hold buildsMu.
func (s *Core) persistBuildsLocked() error {
	return buildstore.Save(s.Builds, s.BuildSeq)
}

// loadBuilds restores build history from disk into the server on startup.
func (s *Core) loadBuilds() {
	file, err := buildstore.Load()
	if err != nil {
		s.Logger.Warn("failed to load build history", "error", err)
		return
	}

	s.Builds = file.Builds
	s.BuildSeq = file.Seq
}

// DefaultBuildPlatform returns the default linux/{GOARCH} platform string for new builds.
func DefaultBuildPlatform() string {
	return fmt.Sprintf("linux/%s", goruntime.GOARCH)
}
