package api

import (
	"context"
	"os"
	"time"

	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/internal/volumeexport"
)

type volumeExportRequest struct {
	Type     string
	FileName string
	Folder   string
	ImageRef string
}

// executeVolumeExport runs a volume export through the runtime and persists the resulting export record.
func (s *Server) executeVolumeExport(ctx context.Context, volumeName string, request volumeExportRequest) (volumeexport.Export, error) {
	store, err := s.volumeExportStore()
	if err != nil {
		return volumeexport.Export{}, err
	}

	exportType := request.Type
	exportID := store.NewID(volumeName)
	archivePath := store.ArchivePath(volumeName, exportID)
	createdAt := time.Now().UTC().Format(time.RFC3339)

	export := volumeexport.Export{
		ID:        exportID,
		Volume:    volumeName,
		Type:      exportType,
		Status:    volumeexport.StatusRunning,
		CreatedAt: createdAt,
		FileName:  request.FileName,
		FilePath:  request.Folder,
		ImageRef:  request.ImageRef,
	}

	if exportType == volumeexport.TypeLocalFile && export.FileName == "" {
		export.FileName = volumeexport.SanitizeExportFileName(volumeName) + ".tar.gz"
	}

	if _, err := store.EnsureExportDir(volumeName, exportID); err != nil {
		return volumeexport.Export{}, err
	}

	if err := store.Save(export); err != nil {
		return volumeexport.Export{}, err
	}

	opts := runtime.VolumeExportOptions{
		VolumeName:  volumeName,
		Type:        exportType,
		FileName:    export.FileName,
		Folder:      export.FilePath,
		ImageRef:    export.ImageRef,
		ArchivePath: archivePath,
	}

	resultPath, err := s.runtime.ExportVolume(ctx, opts)
	if err != nil {
		export.Status = volumeexport.StatusFailed
		export.Error = err.Error()
		_ = store.Save(export)
		return export, err
	}

	export.Status = volumeexport.StatusCompleted
	export.Downloadable = exportType == volumeexport.TypeLocalFile

	switch exportType {
	case volumeexport.TypeLocalFile:
		export.FilePath = resultPath
		if info, statErr := os.Stat(archivePath); statErr == nil {
			export.Size = runtime.FormatBytes(info.Size())
		}
	case volumeexport.TypeLocalImage, volumeexport.TypeNewImage, volumeexport.TypeRegistry:
		export.ImageRef = resultPath
		if info, statErr := os.Stat(archivePath); statErr == nil {
			export.Size = runtime.FormatBytes(info.Size())
		}
	}

	if err := store.Save(export); err != nil {
		return export, err
	}

	return export, nil
}
