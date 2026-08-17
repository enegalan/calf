package dockercli

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
)

// HijackWarning describes another product holding the default Docker CLI path or socket.
type HijackWarning struct {
	Path    string `json:"path"`
	Owner   string `json:"owner"`
	Message string `json:"message"`
}

// DetectHijack reports when /usr/local/bin/docker or /var/run/docker.sock points at Desktop or OrbStack.
func DetectHijack(calfSocket string) []HijackWarning {
	if runtime.GOOS == "windows" {
		return nil
	}

	warnings := make([]HijackWarning, 0)
	for _, path := range []string{"/usr/local/bin/docker", "/opt/homebrew/bin/docker"} {
		if warning, ok := hijackAtPath(path); ok {
			warnings = append(warnings, warning)
		}
	}
	if warning, ok := hijackAtSocket(config.DefaultSystemDockerSocket, calfSocket); ok {
		warnings = append(warnings, warning)
	}
	return warnings
}

// SocketPointsAtCalf reports whether path is calfSocket, or a symlink to it (including a dangling link).
func SocketPointsAtCalf(path, calfSocket string) bool {
	if path == "" || calfSocket == "" {
		return false
	}
	info, err := os.Lstat(path)
	if err != nil {
		return false
	}
	target := path
	if info.Mode()&os.ModeSymlink != 0 {
		link, err := os.Readlink(path)
		if err != nil {
			return false
		}
		if filepath.IsAbs(link) {
			target = link
		} else {
			target = filepath.Join(filepath.Dir(path), link)
		}
	}
	calfAbs, err := filepath.Abs(calfSocket)
	if err != nil {
		return false
	}
	targetAbs, err := filepath.Abs(target)
	if err != nil {
		return false
	}
	return targetAbs == calfAbs
}

// hijackAtPath reports a Docker binary that resolves into Docker Desktop or OrbStack.
func hijackAtPath(path string) (HijackWarning, bool) {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return HijackWarning{}, false
	}
	lower := strings.ToLower(resolved)
	owner := ""
	switch {
	case strings.Contains(lower, "docker.app"):
		owner = "Docker Desktop"
	case strings.Contains(lower, "orbstack"):
		owner = "OrbStack"
	default:
		return HijackWarning{}, false
	}
	return HijackWarning{
		Path:    path,
		Owner:   owner,
		Message: path + " currently points at " + owner + ". Enable “Use calf for Docker CLI” or fix the symlink so docker talks to calf.",
	}, true
}

// hijackAtSocket reports a default docker.sock that is not calf's public socket.
func hijackAtSocket(systemSocket, calfSocket string) (HijackWarning, bool) {
	if SocketPointsAtCalf(systemSocket, calfSocket) {
		return HijackWarning{}, false
	}

	info, err := os.Lstat(systemSocket)
	if err != nil {
		return HijackWarning{}, false
	}
	target := systemSocket
	if info.Mode()&os.ModeSymlink != 0 {
		resolved, err := filepath.EvalSymlinks(systemSocket)
		if err != nil {
			return HijackWarning{
				Path:    systemSocket,
				Owner:   "unknown",
				Message: systemSocket + " is a broken symlink. Enable the default Docker socket in Settings to point it at calf.",
			}, true
		}
		target = resolved
	}
	if SocketPointsAtCalf(target, calfSocket) {
		return HijackWarning{}, false
	}
	owner := "another Docker engine"
	lower := strings.ToLower(target)
	if strings.Contains(lower, "docker.raw") || strings.Contains(lower, "com.docker") {
		owner = "Docker Desktop"
	}
	if strings.Contains(lower, "orbstack") {
		owner = "OrbStack"
	}
	return HijackWarning{
		Path:    systemSocket,
		Owner:   owner,
		Message: systemSocket + " is not calf's socket (" + constants.DockerContextName + "). IDEs that ignore DOCKER_HOST will miss calf.",
	}, true
}
