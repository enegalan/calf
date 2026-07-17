package runtime

import (
	"context"
	"fmt"
	"strings"
)

// isBuildxMissingError reports whether a buildx invocation failed because the plugin is absent.
func isBuildxMissingError(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "buildx") &&
		(strings.Contains(message, "not found") ||
			strings.Contains(message, "unknown command") ||
			strings.Contains(message, "is not a docker command") ||
			strings.Contains(message, "plugin"))
}

// ensureBuildx installs the buildx plugin when missing and bootstraps the default builder.
func ensureBuildx(ctx context.Context, run commandRunner) error {
	if _, err := run(ctx, "nerdctl", "buildx", "version"); err != nil {
		if _, installErr := run(ctx, "sudo", "bash", "-c", "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y docker-buildx"); installErr != nil {
			return fmt.Errorf("install docker-buildx: %w", installErr)
		}
		if _, versionErr := run(ctx, "nerdctl", "buildx", "version"); versionErr != nil {
			return fmt.Errorf("buildx unavailable after install: %w", versionErr)
		}
	}

	if _, err := run(ctx, "nerdctl", "buildx", "inspect", "--bootstrap"); err != nil {
		return fmt.Errorf("bootstrap buildx builder: %w", err)
	}

	return nil
}

// runBuildx runs docker buildx build --load and enriches the parsed output with image metadata.
func runBuildx(ctx context.Context, run commandRunner, contextPath, tag, dockerfile, platform string) (BuildResult, error) {
	if strings.Contains(platform, ",") {
		return BuildResult{}, fmt.Errorf("multi-platform builds are not supported yet; choose a single platform")
	}

	args := BuildxBuildArgs(tag, dockerfile, platform, contextPath)
	output, err := run(ctx, "nerdctl", args...)
	result := ParseBuildOutput(string(output))
	if err != nil {
		return result, err
	}

	return enrichBuildResult(ctx, run, contextPath, dockerfile, tag, platform, result), nil
}

// BuildxBuildArgs builds argv for docker buildx build --load.
func BuildxBuildArgs(tag, dockerfile, platform, contextPath string) []string {
	args := []string{"buildx", "build", "--progress=plain", "--load", "-t", tag}
	if dockerfile != "" {
		args = append(args, "-f", dockerfile)
	}
	if platform != "" {
		args = append(args, "--platform", platform)
	}
	return append(args, contextPath)
}
