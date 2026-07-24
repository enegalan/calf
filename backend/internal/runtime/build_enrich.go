package runtime

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/enegalan/calf/backend/internal/dockerexec"
	"github.com/enegalan/calf/backend/internal/utils"
)

// Regular expressions for parsing Dockerfile dependencies and build image names.
var fromLineRe = regexp.MustCompile(`(?i)^FROM\s+(\S+)`)

// Regular expression for parsing the last image name reported in a build log's "naming to" lines.
var buildImageNameRe = regexp.MustCompile(`(?i)naming to\s+(\S+)`)

// imageInspectRow represents the inspect JSON for an image.
type imageInspectRow struct {
	ID          string   `json:"Id"`
	Digest      string   `json:"Digest"`
	RepoDigests []string `json:"RepoDigests"`
	Size        int64    `json:"Size"`
	RepoTags    []string `json:"RepoTags"`
}

// enrichBuildResult fills build dependencies, artifacts, and tags from the Dockerfile and built image.
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

// parseDockerfileDependencies collects unique FROM image references declared in the Dockerfile.
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
			Platform: PlatformArch(platform),
		})
	}

	return dependencies
}

// enrichDependenciesWithInspect adds digest and platform details to each dependency via image inspect.
func enrichDependenciesWithInspect(ctx context.Context, run commandRunner, result BuildResult, platform string) BuildResult {
	for index, dependency := range result.Dependencies {
		row, err := inspectImageRow(ctx, run, dependency.Source)
		if err != nil {
			continue
		}

		digest := digestFromImageInspect(row)
		if digest == "" {
			continue
		}

		result.Dependencies[index].Digest = digest
		if result.Dependencies[index].Platform == "" {
			result.Dependencies[index].Platform = PlatformArch(platform)
		}
	}

	return result
}

// inspectBuildImage returns build artifacts and tags for the image produced at tag.
func inspectBuildImage(ctx context.Context, run commandRunner, tag, platform string) ([]BuildArtifact, []BuildTag) {
	row, err := inspectImageRow(ctx, run, tag)
	if err != nil {
		return nil, nil
	}

	digest := digestFromImageInspect(row)
	if digest == "" {
		return nil, nil
	}

	size := utils.FormatBytes(row.Size)
	arch := PlatformArch(platform)

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

// inspectImageRow loads the first image inspect document for ref.
func inspectImageRow(ctx context.Context, run commandRunner, ref string) (imageInspectRow, error) {
	output, err := run(ctx, "nerdctl", "image", "inspect", ref)
	if err != nil {
		return imageInspectRow{}, err
	}

	rows, err := decodeInspectDocuments[imageInspectRow](output)
	if err != nil {
		return imageInspectRow{}, err
	}
	if len(rows) == 0 {
		return imageInspectRow{}, fmt.Errorf("image inspect returned no documents for %s", ref)
	}

	return rows[0], nil
}

// digestFromImageInspect picks a content digest from inspect JSON (Digest, RepoDigests, or Id).
func digestFromImageInspect(row imageInspectRow) string {
	if digest := strings.TrimSpace(row.Digest); digest != "" {
		return digest
	}

	for _, repoDigest := range row.RepoDigests {
		repoDigest = strings.TrimSpace(repoDigest)
		if at := strings.LastIndex(repoDigest, "@"); at >= 0 && at+1 < len(repoDigest) {
			return repoDigest[at+1:]
		}
	}

	return strings.TrimSpace(row.ID)
}

// DigestFromInspectFields picks a content digest from image inspect fields.
func DigestFromInspectFields(digest string, repoDigests []string, id string) string {
	return digestFromImageInspect(imageInspectRow{
		Digest:      digest,
		RepoDigests: repoDigests,
		ID:          id,
	})
}

// IsResolvableBuildContext reports whether contextPath is an absolute local directory accessible on disk.
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

// ReadBuildSource loads the Dockerfile content and metadata from a local build context.
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
		Platform: PlatformArch(platform),
	}, nil
}

// CollectGitMetadata returns the short HEAD revision and origin remote URL when contextPath is a git repo.
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

// PlatformArch extracts the architecture segment from an OCI platform string (e.g. linux/amd64 -> amd64).
func PlatformArch(platform string) string {
	if platform == "" {
		return ""
	}

	parts := strings.Split(platform, "/")
	if len(parts) == 2 {
		return parts[1]
	}

	if arch, ok := strings.CutPrefix(platform, "linux/"); ok {
		return arch
	}

	return platform
}

// NormalizeDockerfilePath picks the first existing Dockerfile candidate within contextPath.
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

// ParseImageRefFromBuildLog extracts the last image name reported in a build log's "naming to" lines.
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

// normalizeImageRef strips docker.io/library prefixes for consistent display.
func normalizeImageRef(imageRef string) string {
	imageRef = strings.TrimPrefix(imageRef, "docker.io/library/")
	imageRef = strings.TrimPrefix(imageRef, "library/")
	return imageRef
}

// EnrichSyncedBuild backfills missing build metadata from the local context and build log via the Docker CLI.
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

	if len(enriched.Dependencies) > 0 {
		if len(build.Dependencies) == 0 || dependenciesMissingDigest(build.Dependencies) {
			build.Dependencies = enriched.Dependencies
		}
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

// dependenciesMissingDigest reports whether any dependency is missing a digest.
func dependenciesMissingDigest(dependencies []BuildDependency) bool {
	for _, dependency := range dependencies {
		if strings.TrimSpace(dependency.Digest) == "" {
			return true
		}
	}
	return false
}

// dockerCLIRunner returns a commandRunner that invokes docker with DOCKER_HOST set to socket.
func dockerCLIRunner(socket string) commandRunner {
	return func(ctx context.Context, _ string, args ...string) ([]byte, error) {
		return dockerexec.Run(ctx, socket, args...)
	}
}
