package api

import (
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/utils"
)

// handleVolumesList serves GET /v1/volumes.
func (g *Gateway) handleVolumesList(w http.ResponseWriter, r *http.Request) {
	volumes, err := g.backend.Runtime.ListVolumes(r.Context())
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, volumes)
}

// handleVolumesCreate serves POST /v1/volumes.
func (g *Gateway) handleVolumesCreate(w http.ResponseWriter, r *http.Request) {
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
}

// handleVolumeAction routes /v1/volumes/{name} and subresource paths to the appropriate handler.
func (g *Gateway) handleVolumeAction() http.HandlerFunc {
	return httpkit.ServeRoutes("/v1/volumes/", "volume not found", []httpkit.Route{
		{
			Segments: []string{"files"},
			Method:   http.MethodGet,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleVolumeFiles(w, r, parts[0])
			},
		},
		{
			Segments: []string{"containers"},
			Method:   http.MethodGet,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleVolumeContainers(w, r, parts[0])
			},
		},
		{
			Segments: []string{"clone"},
			Method:   http.MethodPost,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleVolumeClone(w, r, parts[0])
			},
		},
		{
			Segments: []string{"exports"},
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				volumeName := parts[0]
				httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
					http.MethodGet: func(w http.ResponseWriter, r *http.Request) {
						g.handleVolumeExportsList(w, r, volumeName)
					},
					http.MethodPost: func(w http.ResponseWriter, r *http.Request) {
						g.handleVolumeExportCreate(w, r, volumeName)
					},
				})(w, r)
			},
		},
		{
			Segments: []string{"export-schedules"},
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				volumeName := parts[0]
				httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
					http.MethodGet: func(w http.ResponseWriter, r *http.Request) {
						g.handleVolumeExportSchedulesList(w, r, volumeName)
					},
					http.MethodPost: func(w http.ResponseWriter, r *http.Request) {
						g.handleVolumeExportScheduleCreate(w, r, volumeName)
					},
				})(w, r)
			},
		},
		{
			Segments: []string{"export-schedules", "*"},
			Method:   http.MethodPut,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleVolumeExportScheduleUpdate(w, r, parts[0], parts[2])
			},
		},
		{
			Segments: []string{"export-schedules", "*"},
			Method:   http.MethodDelete,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleVolumeExportScheduleDelete(w, r, parts[0], parts[2])
			},
		},
		{
			Segments: []string{"exports", "*", "download"},
			Method:   http.MethodGet,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				g.handleVolumeExportDownload(w, r, parts[0], parts[2])
			},
		},
	}, map[string]httpkit.PartsHandler{
		http.MethodGet: func(w http.ResponseWriter, r *http.Request, parts []string) {
			g.handleVolumeDetail(w, r, parts[0])
		},
		http.MethodDelete: func(w http.ResponseWriter, r *http.Request, parts []string) {
			if err := g.backend.Runtime.RemoveVolume(r.Context(), parts[0]); err != nil {
				httpkit.WriteRuntimeOrFail(w, err)
				return
			}

			utils.WriteOK(w)
		},
	})
}

// handleVolumeDetail serves GET /v1/volumes/{name} with volume inspect data.
func (g *Gateway) handleVolumeDetail(w http.ResponseWriter, r *http.Request, name string) {
	detail, err := g.backend.Runtime.InspectVolume(r.Context(), name)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, detail)
}

// handleVolumeFiles serves GET /v1/volumes/{name}/files for directory listing inside the volume.
func (g *Gateway) handleVolumeFiles(w http.ResponseWriter, r *http.Request, name string) {
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
	containers, err := g.backend.Runtime.VolumeContainers(r.Context(), name)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, containers)
}

// handleVolumeClone serves POST /v1/volumes/{name}/clone to duplicate a volume.
func (g *Gateway) handleVolumeClone(w http.ResponseWriter, r *http.Request, name string) {
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
