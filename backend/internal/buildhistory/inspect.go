package buildhistory

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/enegalan/calf/backend/internal/constants"
	"os"
	"path"
	"strings"
)

// InspectDetail represents the details of a buildx history entry.
type InspectDetail struct {
	Context    string
	Dockerfile string
	Labels     map[string]string
}

// Inspect fetches build context, Dockerfile path, and labels for a buildx history entry.
func Inspect(ctx context.Context, socket, historyID string) (InspectDetail, error) {
	historyID = strings.TrimSpace(historyID)
	if historyID == "" {
		return InspectDetail{}, fmt.Errorf("build history inspect: missing history id")
	}

	output, err := runDocker(
		ctx,
		socket,
		"buildx",
		"history",
		"inspect",
		historyID,
		"--format",
		"{{json .}}",
	)
	if err != nil {
		return InspectDetail{}, err
	}

	return parseInspectDetail(string(output))
}

// parseInspectDetail decodes buildx history inspect JSON into InspectDetail fields.
func parseInspectDetail(output string) (InspectDetail, error) {
	detail := InspectDetail{Dockerfile: "Dockerfile", Labels: make(map[string]string)}

	output = strings.TrimSpace(output)
	if output == "" {
		return detail, nil
	}

	var payload map[string]any
	if err := json.Unmarshal([]byte(output), &payload); err != nil {
		return InspectDetail{}, fmt.Errorf("build history inspect: parse output: %w", err)
	}

	for key, value := range payload {
		switch strings.ToLower(key) {
		case "context":
			if s, ok := value.(string); ok {
				detail.Context = s
			}
		case "dockerfile":
			if s, ok := value.(string); ok && s != "" {
				detail.Dockerfile = s
			}
		case "labels":
			if labels, ok := value.(map[string]any); ok {
				for lk, lv := range labels {
					if s, ok := lv.(string); ok {
						detail.Labels[lk] = s
					}
				}
			}
		}
	}

	if detail.Context == "" {
		detail.Context = resolveContextFromLabels(detail.Labels)
	}

	return detail, nil
}

// resolveContextFromLabels infers a build context path from compose-related container labels.
func resolveContextFromLabels(labels map[string]string) string {
	if workingDir, ok := labels[constants.ComposeWorkingDirLabel]; ok && workingDir != "" {
		if _, err := os.Stat(workingDir); err == nil {
			return workingDir
		}
	}

	if configFiles, ok := labels[constants.ComposeConfigFilesLabel]; ok {
		for _, part := range strings.Split(configFiles, ",") {
			part = strings.TrimSpace(part)
			if part == "" {
				continue
			}
			if _, err := os.Stat(part); err == nil {
				return path.Dir(part)
			}
		}
	}

	return ""
}
