package buildhistory

import (
	"context"
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
		"Context={{.Context}} Dockerfile={{.Dockerfile}}",
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

	for _, part := range strings.Fields(strings.TrimSpace(output)) {
		if value, ok := strings.CutPrefix(part, "Context="); ok {
			detail.Context = value
			continue
		}
		if value, ok := strings.CutPrefix(part, "Dockerfile="); ok && value != "" {
			detail.Dockerfile = value
		}
	}

	return detail
}
