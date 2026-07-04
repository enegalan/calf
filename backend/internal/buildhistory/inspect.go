package buildhistory

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

type InspectDetail struct {
	Context    string
	Dockerfile string
}

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

	detail := parseInspectDetail(string(output))
	if detail.Context == "" {
		return InspectDetail{}, fmt.Errorf("build history inspect: missing context")
	}

	return detail, nil
}

func parseInspectDetail(output string) InspectDetail {
	detail := InspectDetail{Dockerfile: "Dockerfile"}

	output = strings.TrimSpace(output)
	if output == "" {
		return detail
	}

	var payload map[string]string
	if err := json.Unmarshal([]byte(output), &payload); err != nil {
		return detail
	}

	for key, value := range payload {
		switch strings.ToLower(key) {
		case "context":
			detail.Context = value
		case "dockerfile":
			if value != "" {
				detail.Dockerfile = value
			}
		}
	}

	return detail
}
