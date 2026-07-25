package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/enegalan/calf/backend/internal/constants"
)

// ConfigDir returns ~/.config/calf.
func ConfigDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(home, ".config", "calf"), nil
}

// MountsDir returns ~/.config/calf/mounts.
func MountsDir() (string, error) {
	dir, err := ConfigDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(dir, "mounts"), nil
}

// MountsSubdir returns ~/.config/calf/mounts/<name>, creating the directory when missing.
func MountsSubdir(name string) (string, error) {
	dir, err := MountsDir()
	if err != nil {
		return "", err
	}

	root := filepath.Join(dir, name)
	if err := os.MkdirAll(root, 0o755); err != nil {
		return "", fmt.Errorf("create %s: %w", root, err)
	}

	return root, nil
}

// DefaultDockerSocketPath returns ~/.config/calf/docker.sock.
func DefaultDockerSocketPath() string {
	dir, err := ConfigDir()
	if err != nil {
		return ""
	}

	return filepath.Join(dir, "docker.sock")
}

// DefaultDiskImagePath returns ~/.config/calf/guest/<vmName>/disk.raw.
func DefaultDiskImagePath(vmName string) string {
	if vmName == "" {
		vmName = constants.DefaultVMName
	}
	dir, err := ConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "guest", vmName, "disk.raw")
}

// ExpandHomePath expands a leading ~/ to the user home directory.
func ExpandHomePath(path string) string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return ""
	}
	if trimmed == "~" {
		home, err := os.UserHomeDir()
		if err != nil {
			return trimmed
		}
		return home
	}
	if strings.HasPrefix(trimmed, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return trimmed
		}
		return filepath.Join(home, trimmed[2:])
	}
	return trimmed
}

// EffectiveDiskImage returns the absolute guest disk image path for cfg.
func EffectiveDiskImage(cfg Config) string {
	if path := ExpandHomePath(cfg.DiskImage); path != "" {
		return path
	}
	return DefaultDiskImagePath(cfg.VMName)
}

// BuildsFilePath returns ~/.config/calf/builds.json.
func BuildsFilePath() (string, error) {
	dir, err := ConfigDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(dir, "builds.json"), nil
}

// EnsureMountsDir returns ~/.config/calf/mounts, creating the directory when missing.
func EnsureMountsDir() (string, error) {
	dir, err := MountsDir()
	if err != nil {
		return "", err
	}

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("create %s: %w", dir, err)
	}

	return dir, nil
}

// HostMountToVMPath maps a host path under MountsDir to its Lima VM mount at /mnt/calf/...
func HostMountToVMPath(hostPath string) (string, error) {
	mountsRoot, err := MountsDir()
	if err != nil {
		return "", fmt.Errorf("resolve mounts directory: %w", err)
	}

	rel, err := filepath.Rel(mountsRoot, hostPath)
	if err != nil {
		return "", fmt.Errorf("map host path %q to VM path: %w", hostPath, err)
	}
	if strings.HasPrefix(rel, "..") {
		return "", fmt.Errorf("host path %q is outside mounts directory %q", hostPath, mountsRoot)
	}

	return "/mnt/calf/" + filepath.ToSlash(rel), nil
}
