package api

import (
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/daemon"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// handleBuildsList serves GET /v1/builds.
func (g *Gateway) handleBuildsList(w http.ResponseWriter, r *http.Request) {
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
}

// handleBuildsCreate serves POST /v1/builds.
func (g *Gateway) handleBuildsCreate(w http.ResponseWriter, r *http.Request) {
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

	platform := strings.TrimSpace(payload.Platform)
	if platform == "" {
		platform = daemon.DefaultBuildPlatform()
	}
	if strings.Contains(platform, ",") {
		httpkit.WriteError(w, http.StatusBadRequest, "multi-platform builds are not supported yet; choose a single platform")
		return
	}

	build := g.backend.NewBuild(payload.Context, payload.Tag, payload.Dockerfile, platform, "running")
	go g.backend.RunBuildJob(build.ID, payload.Context, payload.Tag, payload.Dockerfile, platform)
	httpkit.WriteJSON(w, http.StatusAccepted, build)
}

// handleBuildAction routes /v1/builds/{id} subpaths and serves GET for a single build record.
func (g *Gateway) handleBuildAction() http.HandlerFunc {
	return httpkit.ServeRoutes("/v1/builds/", "build not found", []httpkit.Route{
		{
			Segments: []string{"source"},
			Method:   http.MethodGet,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleBuildSource(w, r, parts[0])
			},
		},
		{
			Segments: []string{"logs"},
			Method:   http.MethodGet,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleBuildLogs(w, r, parts[0])
			},
		},
	}, map[string]httpkit.PartsHandler{
		http.MethodGet: func(w http.ResponseWriter, r *http.Request, parts []string) {
			build, ok := g.backend.GetBuild(parts[0])
			if !ok {
				httpkit.WriteError(w, http.StatusNotFound, "build not found")
				return
			}

			build = g.backend.EnrichHistoryBuildIfNeeded(r.Context(), build)
			httpkit.WriteJSON(w, http.StatusOK, build)
		},
	})
}

// handleBuildSource serves GET /v1/builds/{id}/source with Dockerfile content and context metadata.
func (g *Gateway) handleBuildSource(w http.ResponseWriter, r *http.Request, buildID string) {
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
