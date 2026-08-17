package daemon

import (
	"context"
	"os"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/internal/utils"
	"github.com/enegalan/calf/backend/internal/volumeexport"
)

// VolumeExportRequest represents a request to export a volume.
type VolumeExportRequest struct {
	Type     string
	FileName string
	Folder   string
	ImageRef string
}

// volumeExportStore opens the on-disk store for volume export metadata.
func (s *Core) volumeExportStore() (*volumeexport.Store, error) {
	return volumeexport.NewStore()
}

// VolumeExportStore opens the on-disk store for volume export metadata.
func (s *Core) VolumeExportStore() (*volumeexport.Store, error) {
	return s.volumeExportStore()
}

// SubscribeLogs multiplexes container log lines to a subscriber channel.
func (s *Core) SubscribeLogs(containerID string) (<-chan string, func()) {
	return s.logBroadcaster.subscribe(s.Runtime, containerID)
}

// SubscribeAllLogs fans in log lines from every currently running container.
func (s *Core) SubscribeAllLogs(ctx context.Context) (<-chan string, func(), error) {
	containers, err := s.ListContainers(ctx)
	if err != nil {
		return nil, nil, err
	}
	out := make(chan string, 256)
	unsubs := make([]func(), 0)
	for _, container := range containers {
		state := strings.ToLower(container.State)
		if state != "running" && state != "paused" {
			continue
		}
		lines, unsub := s.SubscribeLogs(container.ID)
		unsubs = append(unsubs, unsub)
		name := container.Name
		if name == "" {
			name = container.ID
		}
		go func(prefix string, ch <-chan string) {
			for line := range ch {
				select {
				case out <- prefix + " | " + line:
				default:
				}
			}
		}(name, lines)
	}
	cancel := func() {
		for _, unsub := range unsubs {
			unsub()
		}
	}
	return out, cancel, nil
}

// ExecuteVolumeExport runs a volume export through the runtime and persists the resulting export record.
func (s *Core) ExecuteVolumeExport(ctx context.Context, volumeName string, request VolumeExportRequest) (volumeexport.Export, error) {
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
		Status:    constants.JobStatusRunning,
		CreatedAt: createdAt,
		FileName:  request.FileName,
		FilePath:  request.Folder,
		ImageRef:  request.ImageRef,
	}

	if exportType == constants.VolumeExportTypeLocalFile && export.FileName == "" {
		export.FileName = utils.SanitizeExportFileName(volumeName) + ".tar.gz"
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

	resultPath, err := s.Runtime.ExportVolume(ctx, opts)
	if err != nil {
		export.Status = constants.JobStatusFailed
		export.Error = err.Error()
		_ = store.Save(export)
		return export, err
	}

	export.Status = constants.JobStatusCompleted
	export.Downloadable = exportType == constants.VolumeExportTypeLocalFile

	switch exportType {
	case constants.VolumeExportTypeLocalFile:
		export.FilePath = resultPath
		if info, statErr := os.Stat(archivePath); statErr == nil {
			export.Size = utils.FormatBytes(info.Size())
		}
	case constants.VolumeExportTypeLocalImage, constants.VolumeExportTypeNewImage, constants.VolumeExportTypeRegistry:
		export.ImageRef = resultPath
		if info, statErr := os.Stat(archivePath); statErr == nil {
			export.Size = utils.FormatBytes(info.Size())
		}
	}

	if err := store.Save(export); err != nil {
		return export, err
	}

	return export, nil
}
