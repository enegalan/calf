package api

import (
	"github.com/enegalan/calf/backend/internal/httpkit"
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/internal/daemon"
)

// handleBuilds serves GET /v1/builds and POST /v1/builds for listing and starting image builds.
func (g *Gateway) handleBuilds(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		tagFilter := strings.TrimSpace(r.URL.Query().Get("tag"))
		g.backend.BuildsMu.RLock()
		builds := append([]runtime.Build{}, g.backend.Builds...)
		g.backend.BuildsMu.RUnlock()

		if tagFilter != "" {
			filtered := make([]runtime.Build, 0)
			for _, build := range builds {
				if build.Tag == tagFilter {
					filtered = append(filtered, build)
				}
			}
			builds = filtered
		}

		httpkit.WriteJSON(w, http.StatusOK, builds)
	case http.MethodPost:
		var payload struct {
			Context    string `json:"context"`
			Tag        string `json:"tag"`
			Dockerfile string `json:"dockerfile"`
			Platform   string `json:"platform"`
		}

		if err := httpkit.JSONDecode(r, &payload); err != nil {
			httpkit.WriteError(w, http.StatusBadRequest, err.Error())
			return
		}

		if payload.Context == "" || payload.Tag == "" {
			httpkit.WriteError(w, http.StatusBadRequest, "context and tag are required")
			return
		}

		platform := payload.Platform
		if platform == "" {
			platform = daemon.DefaultBuildPlatform()
		}

		build := g.backend.NewBuild(payload.Context, payload.Tag, payload.Dockerfile, platform, "running")
		go g.backend.RunBuildJob(build.ID, payload.Context, payload.Tag, payload.Dockerfile, platform)
		httpkit.WriteJSON(w, http.StatusAccepted, build)
	default:
		httpkit.MethodNotAllowed(w, r)
	}
}

// handleBuildAction routes /v1/builds/{id} subpaths and serves GET for a single build record.
func (g *Gateway) handleBuildAction(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/v1/builds/")
	parts := strings.Split(path, "/")
	if len(parts) == 0 || parts[0] == "" {
		httpkit.WriteError(w, http.StatusNotFound, "build not found")
		return
	}

	buildID := parts[0]
	if len(parts) == 2 && parts[1] == "source" {
		g.handleBuildSource(w, r, buildID)
		return
	}
	if len(parts) == 2 && parts[1] == "logs" {
		g.handleBuildLogs(w, r, buildID)
		return
	}

	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	build, ok := g.backend.GetBuild(buildID)
	if !ok {
		httpkit.WriteError(w, http.StatusNotFound, "build not found")
		return
	}

	build = g.backend.EnrichHistoryBuildIfNeeded(r.Context(), build)

	httpkit.WriteJSON(w, http.StatusOK, build)
}

// handleBuildSource serves GET /v1/builds/{id}/source with Dockerfile content and context metadata.
func (g *Gateway) handleBuildSource(w http.ResponseWriter, r *http.Request, buildID string) {
	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	build, ok := g.backend.GetBuild(buildID)
	if !ok {
		httpkit.WriteError(w, http.StatusNotFound, "build not found")
		return
	}

	contextPath, dockerfile := g.backend.ResolveBuildSourcePaths(r.Context(), build)
	if !runtime.IsResolvableBuildContext(contextPath) {
		httpkit.WriteError(w, http.StatusNotFound, "Dockerfile source is not available for this build")
		return
	}

	source, err := runtime.ReadBuildSource(contextPath, dockerfile, build.Platform)
	if err != nil {
		httpkit.WriteError(w, http.StatusNotFound, err.Error())
		return
	}

	if build.Context != contextPath || build.Dockerfile != dockerfile {
		g.backend.UpdateBuildSourcePaths(buildID, contextPath, dockerfile)
	}

	httpkit.WriteJSON(w, http.StatusOK, source)
}

// handleBuildLogs serves GET /v1/builds/{id}/logs with raw log output and parsed build steps.
func (g *Gateway) handleBuildLogs(w http.ResponseWriter, r *http.Request, buildID string) {
	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	build, ok := g.backend.GetBuild(buildID)
	if !ok {
		httpkit.WriteError(w, http.StatusNotFound, "build not found")
		return
	}

	build = g.backend.EnrichHistoryBuildIfNeeded(r.Context(), build)

	steps := build.Steps
	if steps == nil {
		steps = []runtime.BuildStep{}
	}

	httpkit.WriteJSON(w, http.StatusOK, map[string]any{
		"raw_log": build.RawLog,
		"steps":   steps,
	})
}
