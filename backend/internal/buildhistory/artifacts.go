package buildhistory

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"

	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/internal/utils"
)

// attachmentRow represents a row in the buildx history inspect attachment format.
type attachmentRow struct {
	Type     string
	Platform string
	Digest   string
}

// ociManifest represents an OCI image manifest.
type ociManifest struct {
	Config struct {
		MediaType string `json:"mediaType"`
		Digest    string `json:"digest"`
		Size      int64  `json:"size"`
	} `json:"config"`
}

// BuildArtifacts lists OCI manifest and provenance attachments for a buildx history entry.
func BuildArtifacts(ctx context.Context, socket, historyID, platform string) ([]runtime.BuildArtifact, error) {
	historyID = strings.TrimSpace(historyID)
	if historyID == "" {
		return nil, fmt.Errorf("build history artifacts: missing history id")
	}

	attachments, err := listAttachments(ctx, socket, historyID)
	if err != nil {
		return nil, err
	}

	artifacts := make([]runtime.BuildArtifact, 0, len(attachments)+1)
	manifestPlatform := runtime.PlatformArch(platform)

	for _, attachment := range attachments {
		switch attachment.Type {
		case "application/vnd.oci.image.manifest.v1+json":
			if attachment.Platform != "" {
				manifestPlatform = runtime.PlatformArch(attachment.Platform)
			}

			manifestArtifacts, err := manifestArtifacts(ctx, socket, historyID, attachment.Digest, manifestPlatform)
			if err != nil {
				slog.Warn("skipping manifest attachment", "history_id", historyID, "digest", attachment.Digest, "platform", manifestPlatform, "error", err)
				continue
			}
			artifacts = append(artifacts, manifestArtifacts...)
		case "https://slsa.dev/provenance/v0.2":
			artifact, err := attachmentArtifact(ctx, socket, historyID, attachment, "Provenance v1", manifestPlatform)
			if err != nil {
				slog.Debug("skipping provenance attachment", "history_id", historyID, "digest", attachment.Digest, "platform", manifestPlatform, "error", err)
				continue
			}
			artifacts = append(artifacts, artifact)
		}
	}

	if len(artifacts) == 0 {
		return []runtime.BuildArtifact{}, nil
	}

	return orderBuildArtifacts(artifacts), nil
}

// listAttachments queries buildx history inspect for attachment metadata rows.
func listAttachments(ctx context.Context, socket, historyID string) ([]attachmentRow, error) {
	output, err := runDocker(
		ctx,
		socket,
		"buildx",
		"history",
		"inspect",
		historyID,
		"--format",
		"{{range .Attachments}}TYPE={{.Type}}|PLATFORM={{.Platform}}|DIGEST={{.Digest}}{{println}}{{end}}",
	)
	if err != nil {
		return nil, err
	}

	return parseAttachmentRows(string(output)), nil
}

// parseAttachmentRows parses buildx attachment format lines into structured rows.
func parseAttachmentRows(output string) []attachmentRow {
	rows := make([]attachmentRow, 0)
	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		row := attachmentRow{}
		for _, part := range strings.Split(line, "|") {
			if val, ok := strings.CutPrefix(part, "TYPE="); ok {
				row.Type = val
			} else if val, ok := strings.CutPrefix(part, "PLATFORM="); ok {
				row.Platform = val
			} else if val, ok := strings.CutPrefix(part, "DIGEST="); ok {
				row.Digest = val
			}
		}

		if row.Type == "" || row.Digest == "" {
			continue
		}

		rows = append(rows, row)
	}

	return rows
}

// manifestArtifacts builds artifact entries from an OCI image manifest attachment body.
func manifestArtifacts(ctx context.Context, socket, historyID, digest, platform string) ([]runtime.BuildArtifact, error) {
	output, err := attachmentBody(ctx, socket, historyID, digest)
	if err != nil {
		return nil, err
	}

	var manifest ociManifest
	if err := json.Unmarshal(output, &manifest); err != nil {
		return nil, err
	}

	if manifest.Config.Digest == "" {
		return nil, fmt.Errorf("build history artifacts: missing manifest config")
	}

	return []runtime.BuildArtifact{
		{
			Name:     manifest.Config.MediaType,
			Platform: platform,
			Digest:   manifest.Config.Digest,
			Size:     utils.FormatBytes(manifest.Config.Size),
		},
	}, nil
}

// attachmentArtifact builds a single artifact entry from a non-manifest history attachment.
func attachmentArtifact(
	ctx context.Context,
	socket, historyID string,
	attachment attachmentRow,
	name, platform string,
) (runtime.BuildArtifact, error) {
	output, err := attachmentBody(ctx, socket, historyID, attachment.Digest)
	if err != nil {
		return runtime.BuildArtifact{}, err
	}

	artifactPlatform := platform

	return runtime.BuildArtifact{
		Name:     name,
		Platform: artifactPlatform,
		Digest:   digestForBytes(output),
		Size:     utils.FormatBytes(int64(len(output))),
	}, nil
}

// attachmentBody fetches the raw bytes of a buildx history attachment by digest.
func attachmentBody(ctx context.Context, socket, historyID, digest string) ([]byte, error) {
	output, err := runDocker(ctx, socket, "buildx", "history", "inspect", "attachment", historyID, digest)
	if err != nil {
		return nil, err
	}

	return utils.TrimOutputBytes(output), nil
}

// FetchArtifactBytes returns the raw JSON bytes for a build history artifact digest.
func FetchArtifactBytes(ctx context.Context, socket, historyID, digest string) ([]byte, error) {
	historyID = strings.TrimSpace(historyID)
	digest = strings.TrimSpace(digest)
	if historyID == "" {
		return nil, fmt.Errorf("build history artifact: missing history id")
	}
	if digest == "" {
		return nil, fmt.Errorf("build history artifact: missing digest")
	}

	if body, err := attachmentBody(ctx, socket, historyID, digest); err == nil && len(body) > 0 {
		return body, nil
	}

	attachments, err := listAttachments(ctx, socket, historyID)
	if err != nil {
		return nil, err
	}

	for _, attachment := range attachments {
		body, err := attachmentBody(ctx, socket, historyID, attachment.Digest)
		if err != nil || len(body) == 0 {
			continue
		}

		if attachment.Digest == digest || digestForBytes(body) == digest {
			return body, nil
		}

		if attachment.Type != "application/vnd.oci.image.manifest.v1+json" {
			continue
		}

		var manifest ociManifest
		if err := json.Unmarshal(body, &manifest); err != nil {
			continue
		}
		if manifest.Config.Digest != digest {
			continue
		}

		if configBody, err := attachmentBody(ctx, socket, historyID, manifest.Config.Digest); err == nil && len(configBody) > 0 {
			return configBody, nil
		}

		return body, nil
	}

	return nil, fmt.Errorf("build history artifact not found for digest %s", digest)
}

// digestForBytes returns a sha256 content digest prefixed for OCI-style artifact display.
func digestForBytes(data []byte) string {
	if len(data) == 0 {
		return ""
	}

	hash := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(hash[:])
}

// orderBuildArtifacts returns artifacts with config and provenance entries first.
func orderBuildArtifacts(artifacts []runtime.BuildArtifact) []runtime.BuildArtifact {
	byName := make(map[string]runtime.BuildArtifact, len(artifacts))
	for _, artifact := range artifacts {
		byName[artifact.Name] = artifact
	}

	preferred := []string{
		"application/vnd.oci.image.config.v1+json",
		"Provenance v1",
	}

	ordered := make([]runtime.BuildArtifact, 0, len(artifacts))
	seen := make(map[string]struct{}, len(artifacts))
	for _, name := range preferred {
		artifact, ok := byName[name]
		if !ok {
			continue
		}
		ordered = append(ordered, artifact)
		seen[name] = struct{}{}
	}

	for _, artifact := range artifacts {
		if _, ok := seen[artifact.Name]; ok {
			continue
		}
		ordered = append(ordered, artifact)
	}

	return ordered
}
