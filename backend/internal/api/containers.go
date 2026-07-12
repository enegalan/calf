package api

import (
	"context"
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/internal/utils"
)

// handleContainers serves GET /v1/containers with the list of containers.
func (g *Gateway) handleContainers(w http.ResponseWriter, r *http.Request) {
	containers, err := g.backend.Runtime.ListContainers(r.Context())
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, containers)
}

// handleContainerAction routes /v1/containers/{id} and subresource paths to the appropriate handler.
func (g *Gateway) handleContainerAction() http.HandlerFunc {
	return httpkit.ServeRoutes("/v1/containers/", "container not found", []httpkit.Route{
		{
			Segments: []string{"logs"},
			Method:   http.MethodGet,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleContainerLogs(w, r, parts[0])
			},
		},
		{
			Segments: []string{"inspect"},
			Method:   http.MethodGet,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleContainerInspect(w, r, parts[0])
			},
		},
		{
			Segments: []string{"mounts"},
			Method:   http.MethodGet,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleContainerMounts(w, r, parts[0])
			},
		},
		{
			Segments: []string{"files"},
			Method:   http.MethodGet,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleContainerFiles(w, r, parts[0])
			},
		},
		{
			Segments: []string{"exec"},
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				id := parts[0]
				httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
					http.MethodGet: func(w http.ResponseWriter, r *http.Request) {
						g.handleContainerExecWebSocket(w, r, id)
					},
					http.MethodPost: func(w http.ResponseWriter, r *http.Request) {
						g.handleContainerExecOnce(w, r, id)
					},
				})(w, r)
			},
		},
		{
			Segments: []string{"stats"},
			Method:   http.MethodGet,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleContainerStats(w, r, parts[0])
			},
		},
		{
			Segments: []string{"start"},
			Method:   http.MethodPost,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleContainerLifecycle(w, r, parts[0], g.backend.Runtime.StartContainer)
			},
		},
		{
			Segments: []string{"stop"},
			Method:   http.MethodPost,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleContainerLifecycle(w, r, parts[0], g.backend.Runtime.StopContainer)
			},
		},
		{
			Segments: []string{"restart"},
			Method:   http.MethodPost,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleContainerLifecycle(w, r, parts[0], g.backend.Runtime.RestartContainer)
			},
		},
	}, map[string]httpkit.PartsHandler{
		http.MethodDelete: func(w http.ResponseWriter, r *http.Request, parts []string) {
			if err := g.backend.Runtime.RemoveContainer(r.Context(), parts[0]); err != nil {
				httpkit.WriteRuntimeOrFail(w, err)
				return
			}

			utils.WriteOK(w)
		},
	})
}

// handleContainerLifecycle runs a container lifecycle action and writes the HTTP response.
func (g *Gateway) handleContainerLifecycle(w http.ResponseWriter, r *http.Request, id string, action func(context.Context, string) error) {
	if err := action(r.Context(), id); err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	utils.WriteOK(w)
}

// handleContainerInspect serves GET /v1/containers/{id}/inspect, optionally filtered by section query param.
func (g *Gateway) handleContainerInspect(w http.ResponseWriter, r *http.Request, id string) {
	inspect, err := g.backend.Runtime.InspectContainer(r.Context(), id)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	section := strings.TrimSpace(r.URL.Query().Get("section"))
	if section != "" {
		inspect, err = runtime.InspectSection(inspect, section)
		if err != nil {
			httpkit.WriteError(w, http.StatusBadRequest, err.Error())
			return
		}
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(inspect)
}

// handleContainerMounts serves GET /v1/containers/{id}/mounts.
func (g *Gateway) handleContainerMounts(w http.ResponseWriter, r *http.Request, id string) {
	mounts, err := g.backend.Runtime.ContainerMounts(r.Context(), id)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, mounts)
}

// handleContainerFiles serves GET /v1/containers/{id}/files for directory listing inside the container.
func (g *Gateway) handleContainerFiles(w http.ResponseWriter, r *http.Request, id string) {
	path := strings.TrimSpace(r.URL.Query().Get("path"))
	files, err := g.backend.Runtime.ListContainerFiles(r.Context(), id, path)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, files)
}

// containerExecRequest represents the JSON payload for POST /v1/containers/{id}/exec.
type containerExecRequest struct {
	Command string `json:"command"`
}

// handleContainerExecOnce serves POST /v1/containers/{id}/exec for a one-shot non-interactive command.
func (g *Gateway) handleContainerExecOnce(w http.ResponseWriter, r *http.Request, id string) {
	var request containerExecRequest
	if err := httpkit.JSONDecode(r, &request); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	output, err := g.backend.Runtime.ExecContainer(r.Context(), id, request.Command)
	if err != nil {
		if output != "" {
			httpkit.WriteJSON(w, http.StatusOK, map[string]string{
				"output": output,
				"error":  err.Error(),
			})
			return
		}

		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, map[string]string{"output": output})
}

// handleContainerStats serves GET /v1/containers/{id}/stats with live resource usage.
func (g *Gateway) handleContainerStats(w http.ResponseWriter, r *http.Request, id string) {
	stats, err := g.backend.Runtime.ContainerStats(r.Context(), id)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, stats)
}
