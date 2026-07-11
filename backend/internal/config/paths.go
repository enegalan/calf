package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
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
func HostMountToVMPath(hostPath string) string {
	mountsRoot, err := MountsDir()
	if err != nil {
		return hostPath
	}

	rel, err := filepath.Rel(mountsRoot, hostPath)
	if err != nil || strings.HasPrefix(rel, "..") {
		return hostPath
	}

	return "/mnt/calf/" + filepath.ToSlash(rel)
}
