package api

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/volumeexport"
)

func (s *Server) volumeExportStore() (*volumeexport.Store, error) {
	return volumeexport.NewStore()
}

func (s *Server) writeVolumeStoreError(w http.ResponseWriter, message string, err error) {
	s.logger.Error(message, "error", err)
	writeError(w, http.StatusInternalServerError, message)
}

func (s *Server) handleVolumeExports(w http.ResponseWriter, r *http.Request, volumeName string) {
	switch r.Method {
	case http.MethodGet:
		s.handleVolumeExportsList(w, r, volumeName)
	case http.MethodPost:
		s.handleVolumeExportCreate(w, r, volumeName)
	default:
		methodNotAllowed(w, r)
	}
}

const volumeExportTimeout = 30 * time.Minute

func (s *Server) handleVolumeExportsList(w http.ResponseWriter, r *http.Request, volumeName string) {
	store, err := s.volumeExportStore()
	if err != nil {
		s.writeVolumeStoreError(w, "failed to open export store", err)
		return
	}

	exports, err := store.List(volumeName)
	if err != nil {
		s.logger.Warn("some volume exports could not be read", "volume", volumeName, "error", err)
	}

	writeJSON(w, http.StatusOK, exports)
}

func (s *Server) handleVolumeExportCreate(w http.ResponseWriter, r *http.Request, volumeName string) {
	var payload struct {
		Type     string `json:"type"`
		FileName string `json:"file_name"`
		Folder   string `json:"folder"`
		ImageRef string `json:"image_ref"`
	}

	if err := jsonDecode(r, &payload); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	exportType := strings.TrimSpace(payload.Type)
	if exportType == "" {
		writeError(w, http.StatusBadRequest, "type is required")
		return
	}

	fileName := strings.TrimSpace(payload.FileName)
	folder := strings.TrimSpace(payload.Folder)
	imageRef := strings.TrimSpace(payload.ImageRef)

	if exportType == volumeexport.TypeLocalFile {
		if fileName == "" {
			fileName = sanitizeExportFileName(volumeName)
		}

		if folder == "" {
			writeError(w, http.StatusBadRequest, "folder is required")
			return
		}
	} else if imageRef == "" {
		writeError(w, http.StatusBadRequest, "image_ref is required")
		return
	}

	exportCtx, cancel := context.WithTimeout(r.Context(), volumeExportTimeout)
	defer cancel()

	export, err := s.executeVolumeExport(exportCtx, volumeName, volumeExportRequest{
		Type:     exportType,
		FileName: fileName,
		Folder:   folder,
		ImageRef: imageRef,
	})
	if err != nil {
		if writeRuntimeError(w, err) {
			return
		}

		s.logger.Error("volume export failed", "volume", volumeName, "error", err)
		writeError(w, http.StatusInternalServerError, "volume export failed")
		return
	}

	writeJSON(w, http.StatusOK, export)
}

func (s *Server) handleVolumeExportDownload(w http.ResponseWriter, r *http.Request, volumeName, exportID string) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	store, err := s.volumeExportStore()
	if err != nil {
		s.writeVolumeStoreError(w, "failed to open export store", err)
		return
	}

	export, err := store.Get(volumeName, exportID)
	if err != nil {
		writeError(w, http.StatusNotFound, "export not found")
		return
	}

	if !export.Downloadable || export.Status != volumeexport.StatusCompleted {
		writeError(w, http.StatusBadRequest, "export is not downloadable")
		return
	}

	archivePath := store.ArchivePath(volumeName, exportID)
	file, err := os.Open(archivePath)
	if err != nil {
		writeError(w, http.StatusNotFound, "export archive not found")
		return
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		s.logger.Error("volume export download stat failed", "volume", volumeName, "export", exportID, "error", err)
		writeError(w, http.StatusInternalServerError, "failed to read export archive")
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
		s.logger.Error("volume export download failed", "volume", volumeName, "export", exportID, "error", err)
	}
}

func sanitizeExportFileName(volumeName string) string {
	replacer := strings.NewReplacer("/", "_", "\\", "_", ":", "_")
	return replacer.Replace(strings.TrimSpace(volumeName)) + ".tar.gz"
}

func formatExportSize(bytes int64) string {
	if bytes < 1024 {
		return fmt.Sprintf("%d B", bytes)
	}

	if bytes < 1024*1024 {
		return fmt.Sprintf("%.1f KB", float64(bytes)/1024)
	}

	if bytes < 1024*1024*1024 {
		return fmt.Sprintf("%.1f MB", float64(bytes)/(1024*1024))
	}

	return fmt.Sprintf("%.1f GB", float64(bytes)/(1024*1024*1024))
}
