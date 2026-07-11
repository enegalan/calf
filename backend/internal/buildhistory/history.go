package buildhistory

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"time"
)

// Row represents a row in the buildx history list output.
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

// HistoryID returns the buildx history identifier from either ID or ref fields.
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

// BuildName returns the display name from either casing variant in buildx JSON output.
func (r Row) BuildName() string {
	if r.Name != "" {
		return r.Name
	}

	return r.NameLower
}

// BuildStatus returns the status string from either casing variant in buildx JSON output.
func (r Row) BuildStatus() string {
	if r.Status != "" {
		return r.Status
	}

	return r.StatusLower
}

// BuildCreatedAt returns the creation timestamp from either casing variant in buildx JSON output.
func (r Row) BuildCreatedAt() string {
	if r.CreatedAt != "" {
		return r.CreatedAt
	}

	return r.CreatedAtLower
}

// BuildDurationMs returns build duration in milliseconds from Duration or created/completed timestamps.
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

// List queries docker buildx history and returns parsed rows.
func List(ctx context.Context, socket string) ([]Row, error) {
	output, err := runDocker(ctx, socket, "buildx", "history", "ls", "--format", "{{json .}}")
	if err != nil {
		return nil, err
	}

	return parseRows(output), nil
}

// ParsePlaintextRows decodes newline-delimited buildx output, accepting plain-text lines when JSON parsing fails.
func ParsePlaintextRows(output []byte) []Row {
	rows := make([]Row, 0)
	scanner := bufio.NewScanner(bytes.NewReader(output))

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var row Row
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			rows = append(rows, Row{
				Name:        line,
				NameLower:   line,
				Status:      "migrated",
				StatusLower: "migrated",
			})
			continue
		}

		if row.BuildName() == "" {
			continue
		}

		rows = append(rows, row)
	}

	return rows
}

// parseRows decodes newline-delimited JSON buildx history list output into rows.
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

// MergeRows appends rows whose history IDs are not already present in existingRefs.
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

// RowByHistoryID indexes rows by their buildx history identifier.
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

// NormalizeStatus maps buildx status strings to calf success, failed, or running values.
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

// NormalizeTag returns a non-empty build tag, defaulting to untagged-build.
func NormalizeTag(name string) string {
	tag := strings.TrimSpace(name)
	if tag == "" {
		return "untagged-build"
	}

	return tag
}

// ParseDurationMs converts a Go duration string to milliseconds, returning 0 on parse failure.
func ParseDurationMs(value string) int64 {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}

	compact := strings.ReplaceAll(value, " ", "")
	duration, err := time.ParseDuration(compact)
	if err != nil {
		return 0
	}

	return duration.Milliseconds()
}
