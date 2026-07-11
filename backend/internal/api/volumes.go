package api

import (
	"github.com/enegalan/calf/backend/internal/httpkit"
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/utils"
)

// handleVolumes serves GET /v1/volumes and POST /v1/volumes for listing and creating volumes.
func (g *Gateway) handleVolumes(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		volumes, err := g.backend.Runtime.ListVolumes(r.Context())
		if err != nil {
			httpkit.WriteRuntimeOrFail(w, err)
			return
		}

		httpkit.WriteJSON(w, http.StatusOK, volumes)
	case http.MethodPost:
		var payload struct {
			Name string `json:"name"`
		}

		if err := httpkit.JSONDecode(r, &payload); err != nil {
			httpkit.WriteError(w, http.StatusBadRequest, err.Error())
			return
		}

		if err := g.backend.Runtime.CreateVolume(r.Context(), payload.Name); err != nil {
			httpkit.WriteRuntimeOrFail(w, err)
			return
		}

		utils.WriteOK(w)
	default:
		httpkit.MethodNotAllowed(w, r)
	}
}

// handleVolumeAction routes /v1/volumes/{name} and subresource paths to the appropriate handler.
func (g *Gateway) handleVolumeAction(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/v1/volumes/")
	parts := strings.Split(path, "/")
	if len(parts) == 0 || parts[0] == "" {
		httpkit.WriteError(w, http.StatusNotFound, "volume not found")
		return
	}

	name := parts[0]

	if len(parts) == 2 {
		switch parts[1] {
		case "files":
			g.handleVolumeFiles(w, r, name)
			return
		case "containers":
			g.handleVolumeContainers(w, r, name)
			return
		case "clone":
			g.handleVolumeClone(w, r, name)
			return
		case "exports":
			g.handleVolumeExports(w, r, name)
			return
		case "export-schedules":
			g.handleVolumeExportSchedules(w, r, name)
			return
		}
	}

	if len(parts) == 3 && parts[1] == "export-schedules" {
		g.handleVolumeExportScheduleItem(w, r, name, parts[2])
		return
	}

	if len(parts) == 4 && parts[1] == "exports" && parts[3] == "download" {
		g.handleVolumeExportDownload(w, r, name, parts[2])
		return
	}

	switch r.Method {
	case http.MethodGet:
		if len(parts) != 1 {
			httpkit.MethodNotAllowed(w, r)
			return
		}

		g.handleVolumeDetail(w, r, name)
	case http.MethodDelete:
		if len(parts) != 1 {
			httpkit.MethodNotAllowed(w, r)
			return
		}

		if err := g.backend.Runtime.RemoveVolume(r.Context(), name); err != nil {
			httpkit.WriteRuntimeOrFail(w, err)
			return
		}

		utils.WriteOK(w)
	default:
		httpkit.MethodNotAllowed(w, r)
	}
}

// handleVolumeDetail serves GET /v1/volumes/{name} with volume inspect data.
func (g *Gateway) handleVolumeDetail(w http.ResponseWriter, r *http.Request, name string) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	detail, err := g.backend.Runtime.InspectVolume(r.Context(), name)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, detail)
}

// handleVolumeFiles serves GET /v1/volumes/{name}/files for directory listing inside the volume.
func (g *Gateway) handleVolumeFiles(w http.ResponseWriter, r *http.Request, name string) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	path := strings.TrimSpace(r.URL.Query().Get("path"))
	files, err := g.backend.Runtime.ListVolumeFiles(r.Context(), name, path)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, files)
}

// handleVolumeContainers serves GET /v1/volumes/{name}/containers listing containers using the volume.
func (g *Gateway) handleVolumeContainers(w http.ResponseWriter, r *http.Request, name string) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	containers, err := g.backend.Runtime.VolumeContainers(r.Context(), name)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, containers)
}

// handleVolumeClone serves POST /v1/volumes/{name}/clone to duplicate a volume.
func (g *Gateway) handleVolumeClone(w http.ResponseWriter, r *http.Request, name string) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodPost {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	var payload struct {
		Name string `json:"name"`
	}

	if err := httpkit.JSONDecode(r, &payload); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	if strings.TrimSpace(payload.Name) == "" {
		httpkit.WriteError(w, http.StatusBadRequest, "name is required")
		return
	}

	if err := g.backend.Runtime.CloneVolume(r.Context(), name, payload.Name); err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, map[string]string{
		"status": "ok",
		"name":   payload.Name,
	})
}
