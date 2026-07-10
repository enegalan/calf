package runtime

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

var fromLineRe = regexp.MustCompile(`(?i)^FROM\s+(\S+)`)
var buildImageNameRe = regexp.MustCompile(`(?i)naming to\s+(\S+)`)

type imageInspectRow struct {
	ID       string   `json:"Id"`
	Digest   string   `json:"Digest"`
	Size     int64    `json:"Size"`
	RepoTags []string `json:"RepoTags"`
}

func enrichBuildResult(ctx context.Context, run commandRunner, contextPath, dockerfile, tag, platform string, result BuildResult) BuildResult {
	if dockerfile == "" {
		dockerfile = "Dockerfile"
	}

	result.Dependencies = parseDockerfileDependencies(contextPath, dockerfile, platform)
	result = enrichDependenciesWithInspect(ctx, run, result, platform)

	if tag != "" {
		artifacts, tags := inspectBuildImage(ctx, run, tag, platform)
		if len(artifacts) > 0 {
			result.Results = append(result.Results, artifacts...)
		}
		if len(tags) > 0 {
			result.Tags = tags
		}
	}

	return result
}

func parseDockerfileDependencies(contextPath, dockerfile, platform string) []BuildDependency {
	path := filepath.Join(contextPath, dockerfile)
	file, err := os.Open(path)
	if err != nil {
		return []BuildDependency{}
	}
	defer file.Close()

	dependencies := make([]BuildDependency, 0)
	seen := make(map[string]struct{})
	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		matches := fromLineRe.FindStringSubmatch(line)
		if len(matches) != 2 {
			continue
		}

		source := strings.Trim(matches[1], "\"'")
		if _, ok := seen[source]; ok {
			continue
		}

		seen[source] = struct{}{}
		dependencies = append(dependencies, BuildDependency{
			Source:   source,
			Platform: platformArch(platform),
		})
	}

	return dependencies
}

func enrichDependenciesWithInspect(ctx context.Context, run commandRunner, result BuildResult, platform string) BuildResult {
	for index, dependency := range result.Dependencies {
		output, err := run(ctx, "nerdctl", "image", "inspect", dependency.Source, "--format", "{{json .}}")
		if err != nil {
			continue
		}

		var row imageInspectRow
		if err := json.Unmarshal(bytesTrim(output), &row); err != nil {
			continue
		}

		digest := row.Digest
		if digest == "" {
			digest = row.ID
		}

		result.Dependencies[index].Digest = digest
		if result.Dependencies[index].Platform == "" {
			result.Dependencies[index].Platform = platformArch(platform)
		}
	}

	return result
}

func inspectBuildImage(ctx context.Context, run commandRunner, tag, platform string) ([]BuildArtifact, []BuildTag) {
	output, err := run(ctx, "nerdctl", "image", "inspect", tag, "--format", "{{json .}}")
	if err != nil {
		return nil, nil
	}

	var row imageInspectRow
	if err := json.Unmarshal(bytesTrim(output), &row); err != nil {
		return nil, nil
	}

	digest := row.Digest
	if digest == "" {
		digest = row.ID
	}

	size := formatBytes(row.Size)
	arch := platformArch(platform)

	artifacts := []BuildArtifact{
		{
			Name:     "application/vnd.docker.container.image.v1+json",
			Platform: arch,
			Digest:   digest,
			Size:     size,
		},
	}

	tags := make([]BuildTag, 0, len(row.RepoTags))
	if len(row.RepoTags) == 0 {
		tags = append(tags, BuildTag{Tag: tag, Digest: digest})
	} else {
		for _, repoTag := range row.RepoTags {
			tags = append(tags, BuildTag{Tag: repoTag, Digest: digest})
		}
	}

	return artifacts, tags
}

func IsResolvableBuildContext(contextPath string) bool {
	if contextPath == "" || contextPath == "docker-cli" {
		return false
	}

	if !filepath.IsAbs(contextPath) {
		return false
	}

	_, err := os.Stat(contextPath)
	return err == nil
}

func ReadBuildSource(contextPath, dockerfile, platform string) (BuildSource, error) {
	if dockerfile == "" {
		dockerfile = "Dockerfile"
	}

	absContext, err := filepath.Abs(contextPath)
	if err != nil {
		return BuildSource{}, err
	}

	sourcePath := filepath.Join(absContext, dockerfile)
	absSource, err := filepath.Abs(sourcePath)
	if err != nil {
		return BuildSource{}, err
	}

	rel, err := filepath.Rel(absContext, absSource)
	if err != nil || strings.HasPrefix(rel, "..") {
		return BuildSource{}, os.ErrPermission
	}

	content, err := os.ReadFile(absSource)
	if err != nil {
		return BuildSource{}, err
	}

	return BuildSource{
		Path:     rel,
		Filename: filepath.Base(absSource),
		Content:  string(content),
		Platform: platformArch(platform),
	}, nil
}

func CollectGitMetadata(contextPath string) (revision, remote string) {
	gitDir := filepath.Join(contextPath, ".git")
	if _, err := os.Stat(gitDir); err != nil {
		return "", ""
	}

	if output, err := exec.Command("git", "-C", contextPath, "rev-parse", "--short", "HEAD").Output(); err == nil {
		revision = strings.TrimSpace(string(output))
	}

	if output, err := exec.Command("git", "-C", contextPath, "remote", "get-url", "origin").Output(); err == nil {
		remote = strings.TrimSpace(string(output))
	}

	return revision, remote
}

func platformArch(platform string) string {
	if platform == "" {
		return ""
	}

	parts := strings.Split(platform, "/")
	if len(parts) == 2 {
		return parts[1]
	}

	return platform
}

func formatBytes(size int64) string {
	if size <= 0 {
		return "0 B"
	}

	const unit = 1024
	if size < unit {
		return fmt.Sprintf("%d B", size)
	}

	div, exp := int64(unit), 0
	for numerator := size / unit; numerator >= unit; numerator /= unit {
		div *= unit
		exp++
	}

	value := float64(size) / float64(div)
	suffix := []string{"KB", "MB", "GB", "TB"}[exp]
	return fmt.Sprintf("%.1f %s", value, suffix)
}

func FormatBytes(size int64) string {
	return formatBytes(size)
}

func bytesTrim(output []byte) []byte {
	return []byte(strings.TrimSpace(string(output)))
}

func NormalizeDockerfilePath(contextPath, dockerfile string) string {
	if dockerfile == "" {
		dockerfile = "Dockerfile"
	}

	if contextPath == "" {
		return dockerfile
	}

	candidates := []string{
		dockerfile,
		filepath.Base(dockerfile),
		"Dockerfile",
	}

	seen := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		candidate = strings.TrimSpace(candidate)
		if candidate == "" {
			continue
		}
		if _, ok := seen[candidate]; ok {
			continue
		}
		seen[candidate] = struct{}{}

		if _, err := os.Stat(filepath.Join(contextPath, candidate)); err == nil {
			return candidate
		}
	}

	return dockerfile
}

func ParseImageRefFromBuildLog(rawLog string) string {
	matches := buildImageNameRe.FindAllStringSubmatch(rawLog, -1)
	for index := len(matches) - 1; index >= 0; index-- {
		match := matches[index]
		if len(match) != 2 {
			continue
		}

		imageRef := strings.TrimSpace(match[1])
		if imageRef == "" {
			continue
		}

		return normalizeImageRef(imageRef)
	}

	return ""
}

func normalizeImageRef(imageRef string) string {
	imageRef = strings.TrimPrefix(imageRef, "docker.io/library/")
	imageRef = strings.TrimPrefix(imageRef, "library/")
	return imageRef
}

func EnrichSyncedBuild(ctx context.Context, socket string, build *Build) {
	if build == nil || socket == "" {
		return
	}

	build.Dockerfile = NormalizeDockerfilePath(build.Context, build.Dockerfile)

	if !IsResolvableBuildContext(build.Context) {
		return
	}

	imageRef := ParseImageRefFromBuildLog(build.RawLog)
	enriched := enrichBuildResult(
		ctx,
		dockerCLIRunner(socket),
		build.Context,
		build.Dockerfile,
		imageRef,
		build.Platform,
		BuildResult{},
	)

	if len(build.Dependencies) == 0 && len(enriched.Dependencies) > 0 {
		build.Dependencies = enriched.Dependencies
	}
	if len(build.Results) == 0 && len(enriched.Results) > 0 {
		build.Results = enriched.Results
	}
	if len(build.Tags) == 0 && len(enriched.Tags) > 0 {
		build.Tags = enriched.Tags
	}

	if build.Dependencies == nil {
		build.Dependencies = []BuildDependency{}
	}
	if build.Results == nil {
		build.Results = []BuildArtifact{}
	}
	if build.Tags == nil {
		build.Tags = []BuildTag{}
	}
}

func dockerCLIRunner(socket string) commandRunner {
	return func(ctx context.Context, _ string, args ...string) ([]byte, error) {
		command := exec.CommandContext(ctx, "docker", args...)
		command.Env = append(os.Environ(), "DOCKER_HOST=unix://"+socket)
		output, err := command.CombinedOutput()
		if err != nil {
			return nil, fmt.Errorf("docker %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
		}

		return output, nil
	}
}
