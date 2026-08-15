package dockercli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	pluginBuildx  = "docker-buildx"
	pluginCompose = "docker-compose"
)

// PluginsStatus reports whether the host Docker CLI can load buildx and compose plugins.
type PluginsStatus struct {
	BuildxAvailable  bool   `json:"buildx_available"`
	ComposeAvailable bool   `json:"compose_available"`
	Hint             string `json:"plugins_hint,omitempty"`
}

// ProbePlugins reports whether buildx and compose resolve under ~/.docker/cli-plugins.
func ProbePlugins() PluginsStatus {
	status := probeInstalledPlugins()
	status.Hint = pluginsHint(status.BuildxAvailable, status.ComposeAvailable)
	return status
}

// EnsureCLIPlugins repairs missing or broken buildx/compose plugins under ~/.docker/cli-plugins.
//
// Uninstalling Docker Desktop often leaves broken symlinks there. Compose then warns that
// buildx is missing and falls back to the classic builder, which fails against calf's socket.
// repaired lists plugin names that were relinked in this call.
func EnsureCLIPlugins() (status PluginsStatus, repaired []string, err error) {
	for _, name := range []string{pluginBuildx, pluginCompose} {
		did, ensureErr := ensurePlugin(name)
		if ensureErr != nil {
			status = ProbePlugins()
			return status, repaired, fmt.Errorf("repair %s: %w", name, ensureErr)
		}
		if did {
			repaired = append(repaired, name)
		}
	}
	status = probeInstalledPlugins()
	status.Hint = pluginsHint(status.BuildxAvailable, status.ComposeAvailable)
	return status, repaired, nil
}

// probeInstalledPlugins only checks ~/.docker/cli-plugins (post-repair truth).
func probeInstalledPlugins() PluginsStatus {
	return PluginsStatus{
		BuildxAvailable:  pluginHealthy(pluginInstallPath(pluginBuildx)),
		ComposeAvailable: pluginHealthy(pluginInstallPath(pluginCompose)),
	}
}

// ensurePlugin makes sure name is a working plugin in ~/.docker/cli-plugins.
func ensurePlugin(name string) (repaired bool, err error) {
	dest := pluginInstallPath(name)
	if pluginHealthy(dest) {
		return false, nil
	}
	candidate := findPluginCandidate(name)
	if candidate == "" {
		// Drop a broken symlink so the CLI does not keep a dead entry.
		if isBrokenPluginPath(dest) {
			_ = os.Remove(dest)
		}
		return false, nil
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return false, fmt.Errorf("create cli-plugins dir: %w", err)
	}
	_ = os.Remove(dest)
	if err := os.Symlink(candidate, dest); err != nil {
		return false, fmt.Errorf("symlink %s -> %s: %w", dest, candidate, err)
	}
	if !pluginHealthy(dest) {
		return false, fmt.Errorf("plugin still unusable after linking %s -> %s", dest, candidate)
	}
	return true, nil
}

// pluginInstallPath returns ~/.docker/cli-plugins/<name>.
func pluginInstallPath(name string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".docker", "cli-plugins", name)
}

// pluginHealthy reports whether path resolves to a regular executable file.
func pluginHealthy(path string) bool {
	if path == "" {
		return false
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return false
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() {
		return false
	}
	if runtime.GOOS == "windows" {
		return true
	}
	return info.Mode()&0o111 != 0
}

// isBrokenPluginPath reports a path that exists as a dangling symlink (or unreadable link).
func isBrokenPluginPath(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Lstat(path)
	if err != nil {
		return false
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return false
	}
	_, err = filepath.EvalSymlinks(path)
	return err != nil
}

// findPluginCandidate returns an absolute path to a working plugin binary, or empty.
func findPluginCandidate(name string) string {
	if path, err := exec.LookPath(name); err == nil {
		if abs, absErr := filepath.Abs(path); absErr == nil && pluginHealthy(abs) {
			return abs
		}
	}
	for _, dir := range pluginCandidateDirs() {
		candidate := filepath.Join(dir, name)
		if abs, err := filepath.Abs(candidate); err == nil {
			candidate = abs
		}
		if pluginHealthy(candidate) {
			return candidate
		}
	}
	if dockerPath, err := exec.LookPath("docker"); err == nil {
		dir := filepath.Dir(dockerPath)
		for _, candidate := range []string{
			filepath.Join(dir, name),
			filepath.Join(dir, "cli-plugins", name),
		} {
			if abs, absErr := filepath.Abs(candidate); absErr == nil {
				candidate = abs
			}
			if pluginHealthy(candidate) {
				return candidate
			}
		}
	}
	return ""
}

// pluginCandidateDirs lists known install locations for Docker CLI plugins.
func pluginCandidateDirs() []string {
	dirs := []string{
		"/opt/homebrew/lib/docker/cli-plugins",
		"/usr/local/lib/docker/cli-plugins",
		"/opt/homebrew/bin",
		"/usr/local/bin",
		"/usr/libexec/docker/cli-plugins",
		"/usr/lib/docker/cli-plugins",
		"/home/linuxbrew/.linuxbrew/lib/docker/cli-plugins",
		"/home/linuxbrew/.linuxbrew/bin",
	}
	if runtime.GOOS == "darwin" {
		dirs = append(dirs,
			"/Applications/OrbStack.app/Contents/MacOS/xbin",
			"/Applications/Docker.app/Contents/Resources/cli-plugins",
		)
	}
	return dirs
}

// pluginsHint returns a short install hint when buildx or compose is missing.
func pluginsHint(buildxOK, composeOK bool) string {
	if buildxOK && composeOK {
		return ""
	}
	missing := make([]string, 0, 2)
	if !buildxOK {
		missing = append(missing, "docker-buildx")
	}
	if !composeOK {
		missing = append(missing, "docker-compose")
	}
	return "Docker CLI plugins missing (" + strings.Join(missing, ", ") +
		"). Install with: brew install " + strings.Join(missing, " ")
}
