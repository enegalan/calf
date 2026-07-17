package runtime

import (
	"os"
	"path/filepath"
	"strings"
)

// ResolveNativeDockerSocket picks the Docker API socket for the Linux native runtime.
// When rootless is true and dockerSocket is empty, a user-owned socket is preferred when present;
// otherwise the system socket is used. An explicit dockerSocket always wins.
func ResolveNativeDockerSocket(dockerSocket string, rootless bool) (socket string, usingRootless bool) {
	if dockerSocket != "" {
		return dockerSocket, isRootlessSocketPath(dockerSocket)
	}

	if rootless {
		if userSocket := firstExistingSocket(rootlessDockerSocketCandidates()...); userSocket != "" {
			return userSocket, true
		}
	}

	return "/var/run/docker.sock", false
}

// rootlessDockerSocketCandidates returns user-scoped Docker socket paths in preference order.
func rootlessDockerSocketCandidates() []string {
	candidates := make([]string, 0, 3)
	if runtimeDir := os.Getenv("XDG_RUNTIME_DIR"); runtimeDir != "" {
		candidates = append(candidates, filepath.Join(runtimeDir, "docker.sock"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates,
			filepath.Join(home, ".docker", "run", "docker.sock"),
			filepath.Join(home, ".docker", "docker.sock"),
		)
	}
	return candidates
}

// firstExistingSocket returns the first path that exists as a usable socket endpoint, or empty.
func firstExistingSocket(paths ...string) string {
	for _, path := range paths {
		if path == "" {
			continue
		}
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		if info.IsDir() {
			continue
		}
		return path
	}
	return ""
}

// isRootlessSocketPath reports whether path looks like a user-scoped Docker socket.
func isRootlessSocketPath(path string) bool {
	if path == "" || path == "/var/run/docker.sock" || path == "/run/docker.sock" {
		return false
	}
	for _, candidate := range rootlessDockerSocketCandidates() {
		if path == candidate {
			return true
		}
	}
	runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
	if runtimeDir != "" && pathHasPrefix(path, runtimeDir) {
		return true
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return false
	}
	return pathHasPrefix(path, filepath.Join(home, ".docker"))
}

// pathHasPrefix reports whether path is under prefix.
func pathHasPrefix(path, prefix string) bool {
	cleanPath := filepath.Clean(path)
	cleanPrefix := filepath.Clean(prefix)
	if cleanPath == cleanPrefix {
		return true
	}
	return strings.HasPrefix(cleanPath, cleanPrefix+string(os.PathSeparator))
}

// dockerHostEnv returns an environment slice with DOCKER_HOST pointing at the unix socket.
func dockerHostEnv(socket string) []string {
	return dockerHostEnvFrom(os.Environ(), socket)
}

// dockerHostEnvFrom sets DOCKER_HOST on a copy of env.
func dockerHostEnvFrom(env []string, socket string) []string {
	return setEnvVar(env, "DOCKER_HOST", "unix://"+socket)
}

// proxyEnvFrom sets HTTP(S)_PROXY variables on a copy of env for rootless engines.
func proxyEnvFrom(env []string, proxy ProxyConfig) []string {
	env = setEnvVar(env, "HTTP_PROXY", proxy.HTTPProxy)
	env = setEnvVar(env, "HTTPS_PROXY", proxy.HTTPSProxy)
	env = setEnvVar(env, "NO_PROXY", proxy.NoProxy)
	env = setEnvVar(env, "http_proxy", proxy.HTTPProxy)
	env = setEnvVar(env, "https_proxy", proxy.HTTPSProxy)
	env = setEnvVar(env, "no_proxy", proxy.NoProxy)
	return env
}

// setEnvVar returns env with key=value, replacing an existing key if present.
func setEnvVar(env []string, key, value string) []string {
	prefix := key + "="
	out := make([]string, len(env), len(env)+1)
	copy(out, env)
	for i, entry := range out {
		if strings.HasPrefix(entry, prefix) {
			out[i] = prefix + value
			return out
		}
	}
	return append(out, prefix+value)
}
