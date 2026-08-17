package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
)

// PauseContainer freezes a running container.
func (o *cliOps) PauseContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}
	_, err := o.runLocal(ctx, "nerdctl", "pause", id)
	return err
}

// ResumeContainer unpauses a paused container.
func (o *cliOps) ResumeContainer(ctx context.Context, id string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}
	_, err := o.runLocal(ctx, "nerdctl", "unpause", id)
	return err
}

// RunImageWith starts a detached container using optional name, ports, env, and volumes.
func (o *cliOps) RunImageWith(ctx context.Context, opts RunImageOptions) (string, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return "", err
	}
	return runImageWith(ctx, o.runLocal, opts)
}

// EmptyVolume deletes all files inside a named volume.
func (o *cliOps) EmptyVolume(ctx context.Context, name string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}
	return emptyVolume(ctx, o.runLocal, name)
}

// ImportVolume restores volume data from a file, local image, or registry image.
func (o *cliOps) ImportVolume(ctx context.Context, opts VolumeImportOptions) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}
	return importVolume(ctx, o.runLocal, opts)
}

// CreateNetwork creates a user-defined Docker network.
func (o *cliOps) CreateNetwork(ctx context.Context, name, driver, subnet string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}
	return createNetwork(ctx, o.runLocal, name, driver, subnet)
}

// WriteContainerFile writes content to a path inside a container via docker cp.
func (o *cliOps) WriteContainerFile(ctx context.Context, id, path string, content []byte) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}
	return writeContainerFile(ctx, o.runLocal, id, path, content)
}

// WriteVolumeFile writes content to a path inside a volume via a temporary container.
func (o *cliOps) WriteVolumeFile(ctx context.Context, name, path string, content []byte) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}
	return writeVolumeFile(ctx, o.runLocal, o.runLocalWithStdin, name, path, content)
}

// ListBuilders returns docker buildx builders.
func (o *cliOps) ListBuilders(ctx context.Context) ([]BuilderInfo, error) {
	if err := requireRunning(ctx, o.status); err != nil {
		return nil, err
	}
	return listBuilders(ctx, o.runLocal)
}

// UseBuilder selects the current docker buildx builder.
func (o *cliOps) UseBuilder(ctx context.Context, name string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("builder name is required")
	}
	_, err := o.runLocal(ctx, "nerdctl", "buildx", "use", name)
	return err
}

// RemoveBuilder deletes a docker buildx builder.
func (o *cliOps) RemoveBuilder(ctx context.Context, name string) error {
	if err := requireRunning(ctx, o.status); err != nil {
		return err
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("builder name is required")
	}
	_, err := o.runLocal(ctx, "nerdctl", "buildx", "rm", name)
	return err
}

// runImageWith builds `docker run -d` arguments from RunImageOptions.
func runImageWith(ctx context.Context, run commandRunner, opts RunImageOptions) (string, error) {
	ref := strings.TrimSpace(opts.Reference)
	if ref == "" {
		return "", fmt.Errorf("image reference is required")
	}
	args := []string{"run", "-d"}
	if name := strings.TrimSpace(opts.Name); name != "" {
		args = append(args, "--name", name)
	}
	for _, port := range opts.Ports {
		port = strings.TrimSpace(port)
		if port == "" {
			continue
		}
		args = append(args, "-p", port)
	}
	for _, env := range opts.Env {
		env = strings.TrimSpace(env)
		if env == "" {
			continue
		}
		args = append(args, "-e", env)
	}
	for _, volume := range opts.Volumes {
		volume = strings.TrimSpace(volume)
		if volume == "" {
			continue
		}
		args = append(args, "-v", volume)
	}
	args = append(args, ref)
	output, err := run(ctx, "nerdctl", args...)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

// emptyVolume removes all files in a named volume using a throwaway Alpine container.
func emptyVolume(ctx context.Context, run commandRunner, name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("volume name is required")
	}
	if _, err := volumeInspectMetadata(ctx, run, name); err != nil {
		return err
	}
	_, err := run(ctx, "nerdctl", "run", "--rm", "-v", name+":/data", constants.AlpineSmokeImage,
		"sh", "-c", "find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} +")
	if err != nil {
		return fmt.Errorf("empty volume %s: %w", name, err)
	}
	return nil
}

// importVolume restores archive or image contents into a volume.
func importVolume(ctx context.Context, run commandRunner, opts VolumeImportOptions) error {
	name := strings.TrimSpace(opts.Name)
	if name == "" {
		return fmt.Errorf("volume name is required")
	}
	if _, err := volumeInspectMetadata(ctx, run, name); err != nil {
		if _, createErr := run(ctx, "nerdctl", "volume", "create", name); createErr != nil {
			return fmt.Errorf("create volume %s: %w", name, createErr)
		}
	}
	source := strings.ToLower(strings.TrimSpace(opts.Source))
	switch source {
	case "file":
		return importVolumeFromFile(ctx, run, name, opts.FilePath)
	case "image":
		return importVolumeFromImage(ctx, run, name, opts.ImageRef, false)
	case "registry":
		return importVolumeFromImage(ctx, run, name, opts.ImageRef, true)
	default:
		return fmt.Errorf("import source must be file, image, or registry")
	}
}

// importVolumeFromFile extracts a gzipped tar into the volume.
func importVolumeFromFile(ctx context.Context, run commandRunner, name, filePath string) error {
	filePath = strings.TrimSpace(filePath)
	if filePath == "" {
		return fmt.Errorf("archive path is required")
	}
	vmPath, err := config.HostMountToVMPath(filePath)
	if err != nil {
		vmPath = filePath
	}
	staging := filepath.Dir(vmPath)
	archive := filepath.Base(vmPath)
	_, err = run(ctx, "nerdctl", "run", "--rm",
		"-v", name+":/data",
		"-v", staging+":/in:ro",
		constants.AlpineSmokeImage,
		"tar", "xzf", "/in/"+archive, "-C", "/data")
	if err != nil {
		return fmt.Errorf("import volume %s from file: %w", name, err)
	}
	return nil
}

// importVolumeFromImage copies /volume-data from an image into the volume.
func importVolumeFromImage(ctx context.Context, run commandRunner, name, imageRef string, pullFirst bool) error {
	imageRef = strings.TrimSpace(imageRef)
	if imageRef == "" {
		return fmt.Errorf("image reference is required")
	}
	if pullFirst {
		if _, err := run(ctx, "nerdctl", "pull", imageRef); err != nil {
			return fmt.Errorf("pull import image %s: %w", imageRef, err)
		}
	}
	_, err := run(ctx, "nerdctl", "run", "--rm",
		"-v", name+":/data",
		imageRef,
		"sh", "-c", "if [ -d /volume-data ]; then cp -a /volume-data/. /data/; else tar xzf /tmp/archive.tar.gz -C /data 2>/dev/null || true; fi")
	if err != nil {
		return fmt.Errorf("import volume %s from image: %w", name, err)
	}
	return nil
}

// writeContainerFile copies bytes into a container path using a host temp file and docker cp.
func writeContainerFile(ctx context.Context, run commandRunner, id, path string, content []byte) error {
	if !isValidContainerPath(path) {
		return fmt.Errorf("invalid path")
	}
	id = strings.TrimSpace(id)
	if id == "" {
		return fmt.Errorf("container id is required")
	}
	tmp, err := os.CreateTemp("", "calf-cp-*")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.Write(content); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp file: %w", err)
	}
	if _, err := run(ctx, "nerdctl", "cp", tmpPath, id+":"+path); err != nil {
		return fmt.Errorf("copy file into container: %w", err)
	}
	return nil
}

// writeVolumeFile writes bytes into a volume path using a throwaway container and stdin.
func writeVolumeFile(ctx context.Context, run commandRunner, runStdin stdinCommandRunner, name, path string, content []byte) error {
	if !isValidContainerPath(path) {
		return fmt.Errorf("invalid path")
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("volume name is required")
	}
	dir := filepath.ToSlash(filepath.Dir(path))
	base := filepath.Base(path)
	script := fmt.Sprintf("mkdir -p %q && cat > %q", "/data"+dir, "/data"+filepath.ToSlash(path))
	if base == "." || base == "/" {
		return fmt.Errorf("invalid path")
	}
	_, err := runStdin(ctx, string(content), "nerdctl", "run", "--rm", "-i",
		"-v", name+":/data",
		constants.AlpineSmokeImage,
		"sh", "-c", script)
	if err != nil {
		return fmt.Errorf("write volume file: %w", err)
	}
	return nil
}

// listBuilders parses `docker buildx ls` JSON lines, falling back to inspect of the current builder.
func listBuilders(ctx context.Context, run commandRunner) ([]BuilderInfo, error) {
	output, err := run(ctx, "nerdctl", "buildx", "ls", "--format", "{{json .}}")
	if err == nil {
		builders := make([]BuilderInfo, 0)
		for _, line := range strings.Split(string(output), "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			var row struct {
				Name         string `json:"Name"`
				Driver       string `json:"Driver"`
				LastActivity string `json:"LastActivity"`
				Current      bool   `json:"Current"`
			}
			if jsonErr := json.Unmarshal([]byte(line), &row); jsonErr != nil {
				continue
			}
			if row.Name == "" {
				continue
			}
			builders = append(builders, BuilderInfo{
				Name:         row.Name,
				Driver:       row.Driver,
				LastActivity: row.LastActivity,
				Selected:     row.Current,
			})
		}
		if len(builders) > 0 {
			return builders, nil
		}
	}
	inspect, inspectErr := run(ctx, "nerdctl", "buildx", "inspect")
	if inspectErr != nil {
		if err != nil {
			return nil, err
		}
		return nil, inspectErr
	}
	info := BuilderInfo{Name: "default", Driver: "docker"}
	for _, line := range strings.Split(string(inspect), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Name:") {
			info.Name = strings.TrimSpace(strings.TrimPrefix(line, "Name:"))
		}
		if strings.HasPrefix(line, "Driver:") {
			info.Driver = strings.TrimSpace(strings.TrimPrefix(line, "Driver:"))
		}
	}
	info.Selected = true
	return []BuilderInfo{info}, nil
}
