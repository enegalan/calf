package api

import (
	"context"
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/daemon"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/internal/utils"
)

// handleContainers serves GET /v1/containers with the list of containers.
func (g *Gateway) handleContainers(w http.ResponseWriter, r *http.Request) {
	r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
	defer cancel()

	containers, err := g.backend.ListContainers(r.Context())
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
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				id := parts[0]
				httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
					http.MethodGet: func(w http.ResponseWriter, r *http.Request) {
						g.handleContainerFiles(w, r, id)
					},
					http.MethodPut: func(w http.ResponseWriter, r *http.Request) {
						g.handleContainerFileWrite(w, r, id)
					},
				})(w, r)
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
				g.handleContainerLifecycle(w, r, parts[0], g.backend.Runtime.StartContainer, true)
			},
		},
		{
			Segments: []string{"stop"},
			Method:   http.MethodPost,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleContainerLifecycle(w, r, parts[0], g.backend.Runtime.StopContainer, false)
			},
		},
		{
			Segments: []string{"pause"},
			Method:   http.MethodPost,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleContainerLifecycle(w, r, parts[0], g.backend.Runtime.PauseContainer, false)
			},
		},
		{
			Segments: []string{"resume"},
			Method:   http.MethodPost,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleContainerLifecycle(w, r, parts[0], g.backend.Runtime.ResumeContainer, true)
			},
		},
		{
			Segments: []string{"restart"},
			Method:   http.MethodPost,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleContainerLifecycle(w, r, parts[0], g.backend.Runtime.RestartContainer, true)
			},
		},
	}, map[string]httpkit.PartsHandler{
		http.MethodDelete: func(w http.ResponseWriter, r *http.Request, parts []string) {
			r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
			defer cancel()

			id := parts[0]
			if err := g.backend.Runtime.RemoveContainer(r.Context(), id); err != nil {
				httpkit.WriteRuntimeOrFail(w, err)
				return
			}

			g.backend.ForgetContainerStats(id)
			utils.WriteOK(w)
		},
	})
}

// handleContainerLifecycle runs a container lifecycle action and writes the HTTP response.
// When wakeEngine is set, Resource Saver is exited and the engine is started first.
func (g *Gateway) handleContainerLifecycle(w http.ResponseWriter, r *http.Request, id string, action func(context.Context, string) error, wakeEngine bool) {
	timeout := constants.DefaultActionTimeout
	if wakeEngine {
		timeout = constants.RuntimeActionTimeout
	}
	r, cancel := httpkit.WithTimeout(r, timeout)
	defer cancel()

	if wakeEngine && !httpkit.EnsureRuntimeOrFail(w, r.Context(), g.backend) {
		return
	}

	if err := action(r.Context(), id); err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	utils.WriteOK(w)
}

// handleContainerInspect serves GET /v1/containers/{id}/inspect, optionally filtered by section query param.
func (g *Gateway) handleContainerInspect(w http.ResponseWriter, r *http.Request, id string) {
	r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
	defer cancel()

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
	r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
	defer cancel()

	mounts, err := g.backend.Runtime.ContainerMounts(r.Context(), id)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, mounts)
}

// handleContainerFiles serves GET /v1/containers/{id}/files for directory listing inside the container.
func (g *Gateway) handleContainerFiles(w http.ResponseWriter, r *http.Request, id string) {
	r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
	defer cancel()

	path := strings.TrimSpace(r.URL.Query().Get("path"))
	files, err := g.backend.Runtime.ListContainerFiles(r.Context(), id, path)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, files)
}

// containerFileWriteRequest is the JSON body for PUT /v1/containers/{id}/files.
type containerFileWriteRequest struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

// handleContainerFileWrite serves PUT /v1/containers/{id}/files.
func (g *Gateway) handleContainerFileWrite(w http.ResponseWriter, r *http.Request, id string) {
	r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
	defer cancel()

	var payload containerFileWriteRequest
	if !httpkit.JSONDecodeOrFail(w, r, &payload) {
		return
	}
	if !httpkit.RequireNonEmpty(w, "path", payload.Path) {
		return
	}
	if err := g.backend.Runtime.WriteContainerFile(r.Context(), id, payload.Path, []byte(payload.Content)); err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}
	utils.WriteOK(w)
}

// containerExecRequest represents the JSON payload for POST /v1/containers/{id}/exec.
type containerExecRequest struct {
	Command string `json:"command"`
}

// handleContainerExecOnce serves POST /v1/containers/{id}/exec for a one-shot non-interactive command.
func (g *Gateway) handleContainerExecOnce(w http.ResponseWriter, r *http.Request, id string) {
	r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
	defer cancel()

	var request containerExecRequest
	if !httpkit.JSONDecodeOrFail(w, r, &request) {
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

// containerStatsResponse is the live stats snapshot plus retained history samples.
type containerStatsResponse struct {
	CPUPerc  string               `json:"cpu_percent"`
	MemUsage string               `json:"mem_usage"`
	MemPerc  string               `json:"mem_percent"`
	NetIO    string               `json:"net_io"`
	BlockIO  string               `json:"block_io"`
	PIDs     string               `json:"pids"`
	Samples  []daemon.StatsSample `json:"samples"`
}

// handleContainerStats serves GET /v1/containers/{id}/stats with live usage and retained samples.
func (g *Gateway) handleContainerStats(w http.ResponseWriter, r *http.Request, id string) {
	r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
	defer cancel()

	stats, err := g.backend.Runtime.ContainerStats(r.Context(), id)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	samples := g.backend.ContainerStatsSamples(id)
	if samples == nil {
		samples = []daemon.StatsSample{}
	}

	httpkit.WriteJSON(w, http.StatusOK, containerStatsResponse{
		CPUPerc:  stats.CPUPerc,
		MemUsage: stats.MemUsage,
		MemPerc:  stats.MemPerc,
		NetIO:    stats.NetIO,
		BlockIO:  stats.BlockIO,
		PIDs:     stats.PIDs,
		Samples:  samples,
	})
}
