package runtime

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
)

// VolumeExportOptions represents the options for a volume export.
type VolumeExportOptions struct {
	VolumeName  string
	Type        string
	FileName    string
	Folder      string
	ImageRef    string
	ArchivePath string
}

// exportVolumeArchive tars a volume into a gzipped archive using a temporary Alpine container.
func exportVolumeArchive(ctx context.Context, run commandRunner, volumeName, archivePath string) error {
	if strings.TrimSpace(volumeName) == "" {
		return fmt.Errorf("volume name is required")
	}

	if strings.TrimSpace(archivePath) == "" {
		return fmt.Errorf("archive path is required")
	}

	if err := os.MkdirAll(filepath.Dir(archivePath), 0o755); err != nil {
		return fmt.Errorf("create archive directory: %w", err)
	}

	stagingDir := filepath.Dir(archivePath)
	archiveName := filepath.Base(archivePath)
	vmStagingDir := config.HostMountToVMPath(stagingDir)

	args := []string{
		"run", "--rm",
		"-v", volumeName + ":/from:ro",
		"-v", vmStagingDir + ":/to",
		constants.AlpineSmokeImage,
		"tar", "czf", "/to/" + archiveName, "-C", "/from", ".",
	}
	if _, err := run(ctx, "nerdctl", args...); err != nil {
		return fmt.Errorf("export volume %s to archive: %w", volumeName, err)
	}

	return nil
}

// exportVolumeToImage exports a volume to a container image via archive staging and nerdctl commit.
func exportVolumeToImage(ctx context.Context, run commandRunner, volumeName, imageRef, archivePath string, overwrite bool) error {
	if strings.TrimSpace(imageRef) == "" {
		return fmt.Errorf("image reference is required")
	}

	if !overwrite {
		if _, err := run(ctx, "nerdctl", "image", "inspect", imageRef); err == nil {
			return fmt.Errorf("image %s already exists", imageRef)
		}
	}

	if err := exportVolumeArchive(ctx, run, volumeName, archivePath); err != nil {
		return err
	}

	if overwrite {
		_, _ = run(ctx, "nerdctl", "rmi", "-f", imageRef)
	}

	containerName := fmt.Sprintf("calf-vol-export-%s", filepath.Base(filepath.Dir(archivePath)))
	_, err := run(ctx, "nerdctl", "run", "-d", "--name", containerName, constants.AlpineSmokeImage, "sleep", "3600")
	if err != nil {
		return fmt.Errorf("start export container: %w", err)
	}

	defer func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cleanupCancel()
		_, _ = run(cleanupCtx, "nerdctl", "rm", "-f", containerName)
	}()

	vmArchivePath := config.HostMountToVMPath(archivePath)
	if _, err := run(ctx, "nerdctl", "cp", vmArchivePath, containerName+":/tmp/archive.tar.gz"); err != nil {
		return fmt.Errorf("copy archive into export container: %w", err)
	}

	if _, err := run(ctx, "nerdctl", "exec", containerName, "sh", "-c", "mkdir -p /volume-data && tar xzf /tmp/archive.tar.gz -C /volume-data"); err != nil {
		return fmt.Errorf("populate export container: %w", err)
	}

	if _, err := run(ctx, "nerdctl", "commit", containerName, imageRef); err != nil {
		return fmt.Errorf("commit export image %s: %w", imageRef, err)
	}

	return nil
}

// exportVolumeToRegistry exports a volume as an image and pushes it to a registry.
func exportVolumeToRegistry(ctx context.Context, run commandRunner, volumeName, imageRef, archivePath string) error {
	if err := exportVolumeToImage(ctx, run, volumeName, imageRef, archivePath, true); err != nil {
		return err
	}

	if err := pushImage(ctx, run, imageRef); err != nil {
		return fmt.Errorf("push export image %s: %w", imageRef, err)
	}

	return nil
}

// copyArchiveToFolder copies a volume export archive to a folder and returns the destination path.
func copyArchiveToFolder(archivePath, folder, fileName string) (string, error) {
	if strings.TrimSpace(folder) == "" {
		return "", fmt.Errorf("destination folder is required")
	}

	if strings.TrimSpace(fileName) == "" {
		fileName = filepath.Base(archivePath)
	}

	if err := os.MkdirAll(folder, 0o755); err != nil {
		return "", fmt.Errorf("create destination folder: %w", err)
	}

	destPath := filepath.Join(folder, fileName)
	source, err := os.Open(archivePath)
	if err != nil {
		return "", fmt.Errorf("open archive: %w", err)
	}
	defer source.Close()

	destination, err := os.Create(destPath)
	if err != nil {
		return "", fmt.Errorf("create destination file: %w", err)
	}
	defer destination.Close()

	if _, err := io.Copy(destination, source); err != nil {
		_ = os.Remove(destPath)
		return "", fmt.Errorf("copy archive to destination: %w", err)
	}

	return destPath, nil
}

// RunVolumeExport orchestrates a volume export according to opts.Type.
func RunVolumeExport(ctx context.Context, run commandRunner, opts VolumeExportOptions) (string, error) {
	switch opts.Type {
	case "local_file":
		if err := exportVolumeArchive(ctx, run, opts.VolumeName, opts.ArchivePath); err != nil {
			return "", err
		}

		destPath, err := copyArchiveToFolder(opts.ArchivePath, opts.Folder, opts.FileName)
		if err != nil {
			return "", err
		}

		return destPath, nil
	case "local_image":
		if err := exportVolumeToImage(ctx, run, opts.VolumeName, opts.ImageRef, opts.ArchivePath, true); err != nil {
			return "", err
		}

		return opts.ImageRef, nil
	case "new_image":
		if err := exportVolumeToImage(ctx, run, opts.VolumeName, opts.ImageRef, opts.ArchivePath, false); err != nil {
			return "", err
		}

		return opts.ImageRef, nil
	case "registry":
		if err := exportVolumeToRegistry(ctx, run, opts.VolumeName, opts.ImageRef, opts.ArchivePath); err != nil {
			return "", err
		}

		return opts.ImageRef, nil
	default:
		return "", fmt.Errorf("unsupported export type %q", opts.Type)
	}
}
