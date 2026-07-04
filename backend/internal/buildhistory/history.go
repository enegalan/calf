package buildhistory

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

type Row struct {
	ID             string `json:"ID"`
	Ref            string `json:"ref"`
	Name           string `json:"Name"`
	NameLower      string `json:"name"`
	Status         string `json:"Status"`
	StatusLower    string `json:"status"`
	CreatedAt      string `json:"CreatedAt"`
	CreatedAtLower string `json:"created_at"`
	CompletedAt    string `json:"completed_at"`
	Duration       string `json:"Duration"`
	CachedSteps    int    `json:"cached_steps"`
	TotalSteps     int    `json:"total_steps"`
}

func (r Row) HistoryID() string {
	if r.ID != "" {
		return r.ID
	}

	if r.Ref == "" {
		return ""
	}

	parts := strings.Split(r.Ref, "/")
	return parts[len(parts)-1]
}

func (r Row) BuildName() string {
	if r.Name != "" {
		return r.Name
	}

	return r.NameLower
}

func (r Row) BuildStatus() string {
	if r.Status != "" {
		return r.Status
	}

	return r.StatusLower
}

func (r Row) BuildCreatedAt() string {
	if r.CreatedAt != "" {
		return r.CreatedAt
	}

	return r.CreatedAtLower
}

func (r Row) BuildDurationMs() int64 {
	if duration := ParseDurationMs(r.Duration); duration > 0 {
		return duration
	}

	created, err := time.Parse(time.RFC3339Nano, r.CreatedAtLower)
	if err != nil {
		return 0
	}

	completed, err := time.Parse(time.RFC3339Nano, r.CompletedAt)
	if err != nil {
		return 0
	}

	return completed.Sub(created).Milliseconds()
}

func List(ctx context.Context, socket string) ([]Row, error) {
	output, err := runDocker(ctx, socket, "buildx", "history", "ls", "--format", "{{json .}}")
	if err != nil {
		return nil, err
	}

	return parseRows(output), nil
}

func parseRows(output []byte) []Row {
	rows := make([]Row, 0)
	scanner := bufio.NewScanner(bytes.NewReader(output))

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var row Row
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			continue
		}

		if row.HistoryID() == "" && row.BuildName() == "" {
			continue
		}

		rows = append(rows, row)
	}

	return rows
}

func MergeRows(existingRefs map[string]struct{}, rows []Row) []Row {
	imported := make([]Row, 0)
	for _, row := range rows {
		historyID := row.HistoryID()
		if historyID == "" {
			continue
		}
		if _, exists := existingRefs[historyID]; exists {
			continue
		}
		imported = append(imported, row)
		existingRefs[historyID] = struct{}{}
	}
	return imported
}

func RowByHistoryID(rows []Row) map[string]Row {
	indexed := make(map[string]Row, len(rows))
	for _, row := range rows {
		historyID := row.HistoryID()
		if historyID == "" {
			continue
		}
		indexed[historyID] = row
	}
	return indexed
}

func NormalizeStatus(status string) string {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "completed", "complete", "success":
		return "success"
	case "error", "failed", "canceled", "cancelled":
		return "failed"
	case "running", "in progress", "in_progress":
		return "running"
	default:
		if status == "" {
			return "success"
		}
		return strings.ToLower(status)
	}
}

func NormalizeTag(name string) string {
	tag := strings.TrimSpace(name)
	if tag == "" {
		return "untagged-build"
	}

	return tag
}

func ParseDurationMs(value string) int64 {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}

	if strings.Contains(value, "m") {
		parts := strings.Fields(value)
		var totalMs int64
		for _, part := range parts {
			if strings.HasSuffix(part, "m") {
				minutes, err := strconv.ParseFloat(strings.TrimSuffix(part, "m"), 64)
				if err == nil {
					totalMs += int64(minutes * float64(time.Minute/time.Millisecond))
				}
				continue
			}
			if strings.HasSuffix(part, "s") {
				seconds, err := strconv.ParseFloat(strings.TrimSuffix(part, "s"), 64)
				if err == nil {
					totalMs += int64(seconds * float64(time.Second/time.Millisecond))
				}
			}
		}
		return totalMs
	}

	if strings.HasSuffix(value, "s") {
		seconds, err := strconv.ParseFloat(strings.TrimSuffix(value, "s"), 64)
		if err == nil {
			return int64(seconds * float64(time.Second/time.Millisecond))
		}
	}

	return 0
}

func runDocker(ctx context.Context, socket string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, "docker", args...)
	command.Env = append(os.Environ(), "DOCKER_HOST=unix://"+socket)
	output, err := command.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("docker %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}

	return output, nil
}
