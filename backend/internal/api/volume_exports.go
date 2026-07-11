package api

import (
	"github.com/enegalan/calf/backend/internal/httpkit"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/daemon"
	"github.com/enegalan/calf/backend/internal/volumeexport"
)

// writeVolumeStoreError logs err and writes a generic 500 JSON error response.
func (g *Gateway) writeVolumeStoreError(w http.ResponseWriter, message string, err error) {
	g.logger.Error(message, "error", err)
	httpkit.WriteError(w, http.StatusInternalServerError, message)
}

// handleVolumeExports routes GET and POST /v1/volumes/{name}/exports.
func (g *Gateway) handleVolumeExports(w http.ResponseWriter, r *http.Request, volumeName string) {
	switch r.Method {
	case http.MethodGet:
		g.handleVolumeExportsList(w, r, volumeName)
	case http.MethodPost:
		g.handleVolumeExportCreate(w, r, volumeName)
	default:
		httpkit.MethodNotAllowed(w, r)
	}
}

// handleVolumeExportsList serves GET /v1/volumes/{name}/exports with past export records.
func (g *Gateway) handleVolumeExportsList(w http.ResponseWriter, r *http.Request, volumeName string) {
	store, err := g.backend.VolumeExportStore()
	if err != nil {
		g.writeVolumeStoreError(w, "failed to open export store", err)
		return
	}

	exports, err := store.List(volumeName)
	if err != nil {
		g.logger.Warn("some volume exports could not be read", "volume", volumeName, "error", err)
	}

	httpkit.WriteJSON(w, http.StatusOK, exports)
}

// handleVolumeExportCreate serves POST /v1/volumes/{name}/exports to run a new volume export.
func (g *Gateway) handleVolumeExportCreate(w http.ResponseWriter, r *http.Request, volumeName string) {
	var payload struct {
		Type     string `json:"type"`
		FileName string `json:"file_name"`
		Folder   string `json:"folder"`
		ImageRef string `json:"image_ref"`
	}

	if err := httpkit.JSONDecode(r, &payload); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	exportType := strings.TrimSpace(payload.Type)
	if exportType == "" {
		httpkit.WriteError(w, http.StatusBadRequest, "type is required")
		return
	}

	fileName := strings.TrimSpace(payload.FileName)
	folder := strings.TrimSpace(payload.Folder)
	imageRef := strings.TrimSpace(payload.ImageRef)

	if exportType == volumeexport.TypeLocalFile {
		if fileName == "" {
			fileName = volumeexport.SanitizeExportFileName(volumeName) + ".tar.gz"
		}

		if folder == "" {
			httpkit.WriteError(w, http.StatusBadRequest, "folder is required")
			return
		}
	} else if imageRef == "" {
		httpkit.WriteError(w, http.StatusBadRequest, "image_ref is required")
		return
	}

	exportCtx, cancel := context.WithTimeout(r.Context(), constants.VolumeExportTimeout)
	defer cancel()

	export, err := g.backend.ExecuteVolumeExport(exportCtx, volumeName, daemon.VolumeExportRequest{
		Type:     exportType,
		FileName: fileName,
		Folder:   folder,
		ImageRef: imageRef,
	})
	if err != nil {
		if httpkit.WriteRuntimeError(w, err) {
			return
		}

		g.logger.Error("volume export failed", "volume", volumeName, "error", err)
		httpkit.WriteError(w, http.StatusInternalServerError, "volume export failed")
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, export)
}

// handleVolumeExportDownload serves GET /v1/volumes/{name}/exports/{id}/download as a gzip attachment.
func (g *Gateway) handleVolumeExportDownload(w http.ResponseWriter, r *http.Request, volumeName, exportID string) {
	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	store, err := g.backend.VolumeExportStore()
	if err != nil {
		g.writeVolumeStoreError(w, "failed to open export store", err)
		return
	}

	export, err := store.Get(volumeName, exportID)
	if err != nil {
		httpkit.WriteError(w, http.StatusNotFound, "export not found")
		return
	}

	if !export.Downloadable || export.Status != volumeexport.StatusCompleted {
		httpkit.WriteError(w, http.StatusBadRequest, "export is not downloadable")
		return
	}

	archivePath := store.ArchivePath(volumeName, exportID)
	file, err := os.Open(archivePath)
	if err != nil {
		httpkit.WriteError(w, http.StatusNotFound, "export archive not found")
		return
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		g.logger.Error("volume export download stat failed", "volume", volumeName, "export", exportID, "error", err)
		httpkit.WriteError(w, http.StatusInternalServerError, "failed to read export archive")
		return
	}

	fileName := export.FileName
	if fileName == "" {
		fileName = filepath.Base(archivePath)
	}

	w.Header().Set("Content-Type", "application/gzip")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", fileName))
	w.Header().Set("Content-Length", fmt.Sprintf("%d", info.Size()))
	w.WriteHeader(http.StatusOK)

	if _, err := io.Copy(w, file); err != nil {
		g.logger.Error("volume export download failed", "volume", volumeName, "export", exportID, "error", err)
	}
}
