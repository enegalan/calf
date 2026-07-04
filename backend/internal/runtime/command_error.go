package runtime

import (
	"fmt"
	"regexp"
	"strings"
)

var ansiEscapePattern = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)

var nerdctlFatalMessagePattern = regexp.MustCompile(`level=fatal msg="([^"]+)"`)

func formatCommandError(output string) string {
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

func isProgressLine(line string) bool {
	return strings.Contains(line, "elapsed:") ||
		strings.Contains(line, "waiting") ||
		strings.Contains(line, "--------------------------------------")
}

func isNamespacedImageReference(ref string) bool {
	name := strings.TrimSpace(ref)
	if colon := strings.LastIndex(name, ":"); colon > strings.LastIndex(name, "/") {
		name = name[:colon]
	}

	return strings.Contains(name, "/")
}

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

func wrapPushError(ref string, err error) error {
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

func FormatCommandError(output string) string {
	return formatCommandError(output)
}

func IsTransientCommandError(err error) bool {
	return isTransientCommandError(err)
}

func isTransientCommandError(err error) bool {
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
		"limactl",
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

func WrapPushError(ref string, err error) error {
	return wrapPushError(ref, err)
}
