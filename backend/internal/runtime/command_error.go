package runtime

import (
	"fmt"
	"regexp"
	"strings"
)

// Regular expression for stripping ANSI escape sequences from command output.
var ansiEscapePattern = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)

// Regular expression for extracting the fatal message from nerdctl/shell command output.
var nerdctlFatalMessagePattern = regexp.MustCompile(`level=fatal msg="([^"]+)"`)

// FormatCommandError extracts a concise human-readable message from nerdctl/shell command output.
func FormatCommandError(output string) string {
	cleaned := ansiEscapePattern.ReplaceAllString(output, "")
	lines := strings.Split(cleaned, "\n")

	for index := len(lines) - 1; index >= 0; index-- {
		line := strings.TrimSpace(lines[index])
		if line == "" || isProgressLine(line) {
			continue
		}

		if matches := nerdctlFatalMessagePattern.FindStringSubmatch(line); len(matches) > 1 {
			return matches[1]
		}

		if strings.HasPrefix(line, "time=") {
			continue
		}

		return line
	}

	cleaned = strings.TrimSpace(cleaned)
	if cleaned == "" {
		return ""
	}

	if len(cleaned) > 500 {
		return cleaned[len(cleaned)-500:]
	}

	return cleaned
}

// isProgressLine reports whether a log line is build/pull progress noise rather than an error.
func isProgressLine(line string) bool {
	return strings.Contains(line, "elapsed:") ||
		strings.Contains(line, "waiting") ||
		strings.Contains(line, "--------------------------------------")
}

// isNamespacedImageReference reports whether ref includes a registry namespace (e.g. user/repo).
func isNamespacedImageReference(ref string) bool {
	name := strings.TrimSpace(ref)
	if colon := strings.LastIndex(name, ":"); colon > strings.LastIndex(name, "/") {
		name = name[:colon]
	}

	return strings.Contains(name, "/")
}

// imageRepositoryName returns the repository component of an image reference without tag or registry prefix.
func imageRepositoryName(ref string) string {
	name := strings.TrimSpace(ref)
	if colon := strings.LastIndex(name, ":"); colon > strings.LastIndex(name, "/") {
		name = name[:colon]
	}

	if slash := strings.LastIndex(name, "/"); slash >= 0 {
		return name[slash+1:]
	}

	return name
}

// WrapPushError augments registry authorization failures with Docker Hub sign-in or tagging hints.
func WrapPushError(ref string, err error) error {
	message := err.Error()
	lower := strings.ToLower(message)
	if !strings.Contains(lower, "authorization") &&
		!strings.Contains(lower, "access denied") &&
		!strings.Contains(lower, "insufficient_scope") {
		return err
	}

	if !isNamespacedImageReference(ref) {
		repository := imageRepositoryName(ref)
		return fmt.Errorf(
			"%s. Tag the image for Docker Hub first, e.g. docker.io/USERNAME/%s:latest, then push again",
			message,
			repository,
		)
	}

	return fmt.Errorf("%s. Sign in to Docker Hub from Settings (browser login), then push again", message)
}

// IsContainerNotFoundError reports whether err indicates a missing container ID.
func IsContainerNotFoundError(err error) bool {
	if err == nil {
		return false
	}

	message := strings.ToLower(err.Error())
	return strings.Contains(message, "no such object") ||
		strings.Contains(message, "no such container")
}

// IsContainerNotRunningError reports whether err indicates the container is stopped.
func IsContainerNotRunningError(err error) bool {
	if err == nil {
		return false
	}

	message := strings.ToLower(err.Error())
	return strings.Contains(message, "is not running") ||
		strings.Contains(message, "container not running")
}

// IsTransientCommandError reports whether err is likely temporary and worth retrying.
func IsTransientCommandError(err error) bool {
	if err == nil {
		return false
	}

	message := strings.ToLower(err.Error())
	transientMarkers := []string{
		"text file busy",
		"transport is closing",
		"connection reset",
		"connection refused",
		"cannot connect to the docker daemon",
		"deadline exceeded",
		"i/o timeout",
		"broken pipe",
	}

	for _, marker := range transientMarkers {
		if strings.Contains(message, marker) {
			return true
		}
	}

	startupPathMarkers := []string{
		"no such file or directory",
		"executable file not found",
	}
	startupContexts := []string{
		"nerdctl",
		"krunkit",
		"gvproxy",
		"containerd",
		"docker.sock",
		"/run/containerd",
	}

	for _, marker := range startupPathMarkers {
		if !strings.Contains(message, marker) {
			continue
		}

		for _, contextMarker := range startupContexts {
			if strings.Contains(message, contextMarker) {
				return true
			}
		}
	}

	return false
}
