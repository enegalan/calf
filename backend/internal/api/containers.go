package api

import (
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/internal/utils"
)

// handleContainers serves GET /v1/containers with the list of containers.
func (s *Server) handleContainers(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	containers, err := s.runtime.ListContainers(r.Context())
	if err != nil {
		writeRuntimeOrFail(w, err)
		return
	}

	writeJSON(w, http.StatusOK, containers)
}

// handleContainerAction routes /v1/containers/{id} and subresource paths to the appropriate handler.
func (s *Server) handleContainerAction(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/v1/containers/")
	parts := strings.Split(path, "/")
	if len(parts) == 0 || parts[0] == "" {
		writeError(w, http.StatusNotFound, "container not found")
		return
	}

	id := parts[0]

	if len(parts) == 2 {
		switch parts[1] {
		case "logs":
			s.handleContainerLogs(w, r, id)
			return
		case "inspect":
			s.handleContainerInspect(w, r, id)
			return
		case "mounts":
			s.handleContainerMounts(w, r, id)
			return
		case "files":
			s.handleContainerFiles(w, r, id)
			return
		case "exec":
			s.handleContainerExec(w, r, id)
			return
		case "stats":
			s.handleContainerStats(w, r, id)
			return
		}
	}

	var err error
	switch r.Method {
	case http.MethodPost:
		if len(parts) != 2 {
			methodNotAllowed(w, r)
			return
		}

		switch parts[1] {
		case "start":
			err = s.runtime.StartContainer(r.Context(), id)
		case "stop":
			err = s.runtime.StopContainer(r.Context(), id)
		case "restart":
			err = s.runtime.RestartContainer(r.Context(), id)
		default:
			methodNotAllowed(w, r)
			return
		}
	case http.MethodDelete:
		err = s.runtime.RemoveContainer(r.Context(), id)
	default:
		methodNotAllowed(w, r)
		return
	}

	if err != nil {
		writeRuntimeOrFail(w, err)
		return
	}

	utils.WriteOK(w)
}

// handleContainerInspect serves GET /v1/containers/{id}/inspect, optionally filtered by section query param.
func (s *Server) handleContainerInspect(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	inspect, err := s.runtime.InspectContainer(r.Context(), id)
	if err != nil {
		writeRuntimeOrFail(w, err)
		return
	}

	section := strings.TrimSpace(r.URL.Query().Get("section"))
	if section != "" {
		inspect, err = runtime.InspectSection(inspect, section)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(inspect)
}

// handleContainerMounts serves GET /v1/containers/{id}/mounts.
func (s *Server) handleContainerMounts(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	mounts, err := s.runtime.ContainerMounts(r.Context(), id)
	if err != nil {
		writeRuntimeOrFail(w, err)
		return
	}

	writeJSON(w, http.StatusOK, mounts)
}

// handleContainerFiles serves GET /v1/containers/{id}/files for directory listing inside the container.
func (s *Server) handleContainerFiles(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	path := strings.TrimSpace(r.URL.Query().Get("path"))
	files, err := s.runtime.ListContainerFiles(r.Context(), id, path)
	if err != nil {
		writeRuntimeOrFail(w, err)
		return
	}

	writeJSON(w, http.StatusOK, files)
}

type containerExecRequest struct {
	Command string `json:"command"`
}

// handleContainerExecOnce serves POST /v1/containers/{id}/exec for a one-shot non-interactive command.
func (s *Server) handleContainerExecOnce(w http.ResponseWriter, r *http.Request, id string) {
	var request containerExecRequest
	if err := jsonDecode(r, &request); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	output, err := s.runtime.ExecContainer(r.Context(), id, request.Command)
	if err != nil {
		if output != "" {
			writeJSON(w, http.StatusOK, map[string]string{
				"output": output,
				"error":  err.Error(),
			})
			return
		}

		writeRuntimeOrFail(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"output": output})
}

// handleContainerStats serves GET /v1/containers/{id}/stats with live resource usage.
func (s *Server) handleContainerStats(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	stats, err := s.runtime.ContainerStats(r.Context(), id)
	if err != nil {
		writeRuntimeOrFail(w, err)
		return
	}

	writeJSON(w, http.StatusOK, stats)
}
