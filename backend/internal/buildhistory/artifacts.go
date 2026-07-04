package buildhistory

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/enegalan/calf/backend/internal/runtime"
)

type attachmentRow struct {
	Type     string
	Platform string
	Digest   string
}

type ociManifest struct {
	Config struct {
		MediaType string `json:"mediaType"`
		Digest    string `json:"digest"`
		Size      int64  `json:"size"`
	} `json:"config"`
}

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
	manifestPlatform := platformArch(platform)

	for _, attachment := range attachments {
		switch attachment.Type {
		case "application/vnd.oci.image.manifest.v1+json":
			if attachment.Platform != "" {
				manifestPlatform = platformArch(attachment.Platform)
			}

			manifestArtifacts, err := manifestArtifacts(ctx, socket, historyID, attachment.Digest, manifestPlatform)
			if err != nil {
				continue
			}
			artifacts = append(artifacts, manifestArtifacts...)
		case "https://slsa.dev/provenance/v0.2":
			artifact, err := attachmentArtifact(ctx, socket, historyID, attachment, "Provenance v1", manifestPlatform)
			if err != nil {
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

func parseAttachmentRows(output string) []attachmentRow {
	rows := make([]attachmentRow, 0)
	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		row := attachmentRow{}
		for _, part := range strings.Split(line, "|") {
			switch {
			case strings.HasPrefix(part, "TYPE="):
				row.Type = strings.TrimPrefix(part, "TYPE=")
			case strings.HasPrefix(part, "PLATFORM="):
				row.Platform = strings.TrimPrefix(part, "PLATFORM=")
			case strings.HasPrefix(part, "DIGEST="):
				row.Digest = strings.TrimPrefix(part, "DIGEST=")
			}
		}

		if row.Type == "" || row.Digest == "" {
			continue
		}

		rows = append(rows, row)
	}

	return rows
}

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
			Size:     runtime.FormatBytes(manifest.Config.Size),
		},
	}, nil
}

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
		Size:     runtime.FormatBytes(int64(len(output))),
	}, nil
}

func attachmentBody(ctx context.Context, socket, historyID, digest string) ([]byte, error) {
	output, err := runDocker(ctx, socket, "buildx", "history", "inspect", "attachment", historyID, digest)
	if err != nil {
		return nil, err
	}

	return bytesTrim(output), nil
}

func digestForBytes(data []byte) string {
	if len(data) == 0 {
		return ""
	}

	hash := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(hash[:])
}

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

func platformArch(platform string) string {
	if platform == "" {
		return ""
	}

	parts := strings.Split(platform, "/")
	if len(parts) == 2 {
		return parts[1]
	}

	if strings.HasPrefix(platform, "linux/") {
		return strings.TrimPrefix(platform, "linux/")
	}

	return platform
}

func bytesTrim(output []byte) []byte {
	return []byte(strings.TrimSpace(string(output)))
}
