package api

import (
	"github.com/enegalan/calf/backend/internal/httpkit"
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/internal/utils"
)

// handleContainers serves GET /v1/containers with the list of containers.
func (g *Gateway) handleContainers(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	containers, err := g.backend.Runtime.ListContainers(r.Context())
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, containers)
}

// handleContainerAction routes /v1/containers/{id} and subresource paths to the appropriate handler.
func (g *Gateway) handleContainerAction(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/v1/containers/")
	parts := strings.Split(path, "/")
	if len(parts) == 0 || parts[0] == "" {
		httpkit.WriteError(w, http.StatusNotFound, "container not found")
		return
	}

	id := parts[0]

	if len(parts) == 2 {
		switch parts[1] {
		case "logs":
			g.handleContainerLogs(w, r, id)
			return
		case "inspect":
			g.handleContainerInspect(w, r, id)
			return
		case "mounts":
			g.handleContainerMounts(w, r, id)
			return
		case "files":
			g.handleContainerFiles(w, r, id)
			return
		case "exec":
			g.handleContainerExec(w, r, id)
			return
		case "stats":
			g.handleContainerStats(w, r, id)
			return
		}
	}

	var err error
	switch r.Method {
	case http.MethodPost:
		if len(parts) != 2 {
			httpkit.MethodNotAllowed(w, r)
			return
		}

		switch parts[1] {
		case "start":
			err = g.backend.Runtime.StartContainer(r.Context(), id)
		case "stop":
			err = g.backend.Runtime.StopContainer(r.Context(), id)
		case "restart":
			err = g.backend.Runtime.RestartContainer(r.Context(), id)
		default:
			httpkit.MethodNotAllowed(w, r)
			return
		}
	case http.MethodDelete:
		err = g.backend.Runtime.RemoveContainer(r.Context(), id)
	default:
		httpkit.MethodNotAllowed(w, r)
		return
	}

	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	utils.WriteOK(w)
}

// handleContainerInspect serves GET /v1/containers/{id}/inspect, optionally filtered by section query param.
func (g *Gateway) handleContainerInspect(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

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
	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	mounts, err := g.backend.Runtime.ContainerMounts(r.Context(), id)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, mounts)
}

// handleContainerFiles serves GET /v1/containers/{id}/files for directory listing inside the container.
func (g *Gateway) handleContainerFiles(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	path := strings.TrimSpace(r.URL.Query().Get("path"))
	files, err := g.backend.Runtime.ListContainerFiles(r.Context(), id, path)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, files)
}

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
	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	stats, err := g.backend.Runtime.ContainerStats(r.Context(), id)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, stats)
}
