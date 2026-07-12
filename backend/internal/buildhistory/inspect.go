package buildhistory

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/enegalan/calf/backend/internal/constants"
	"os"
	"path"
	"path/filepath"
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
		"json",
	)
	if err != nil {
		return InspectDetail{}, err
	}

	return ParseInspectDetail(string(output))
}

// ParseInspectDetail decodes buildx history inspect JSON into InspectDetail fields.
func ParseInspectDetail(output string) (InspectDetail, error) {
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
			parseInspectLabels(value, detail.Labels)
		}
	}

	if detail.Context == "" || detail.Context == "." || !filepath.IsAbs(detail.Context) {
		if resolved := resolveContextFromLabels(detail.Labels); resolved != "" {
			detail.Context = resolved
		}
	}

	return detail, nil
}

// parseInspectLabels decodes buildx label metadata from either a map or a Name/Value array.
func parseInspectLabels(value any, labels map[string]string) {
	switch typed := value.(type) {
	case map[string]any:
		for key, raw := range typed {
			if label, ok := raw.(string); ok {
				labels[key] = label
			}
		}
	case []any:
		for _, item := range typed {
			entry, ok := item.(map[string]any)
			if !ok {
				continue
			}

			name, _ := entry["Name"].(string)
			if name == "" {
				name, _ = entry["name"].(string)
			}

			label, _ := entry["Value"].(string)
			if label == "" {
				label, _ = entry["value"].(string)
			}

			if name != "" {
				labels[name] = label
			}
		}
	}
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
