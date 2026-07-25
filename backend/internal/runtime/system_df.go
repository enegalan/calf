package runtime

import (
	"context"
	"fmt"
	"strings"

	"github.com/enegalan/calf/backend/internal/utils"
)

// DiskUsageRow is one TYPE row from docker/nerdctl system df.
type DiskUsageRow struct {
	Type             string `json:"type"`
	Size             string `json:"size"`
	SizeBytes        int64  `json:"size_bytes"`
	Reclaimable      string `json:"reclaimable"`
	ReclaimableBytes int64  `json:"reclaimable_bytes"`
}

// SystemDiskUsage is the engine disk breakdown from system df.
type SystemDiskUsage struct {
	Rows []DiskUsageRow `json:"rows"`
}

// systemDiskUsage runs nerdctl system df and parses Images/Containers/Volumes/Build Cache rows.
func systemDiskUsage(ctx context.Context, run commandRunner) (SystemDiskUsage, error) {
	output, err := run(ctx, "nerdctl", "system", "df", "--format", "{{.Type}}\t{{.Size}}\t{{.Reclaimable}}")
	if err != nil {
		return SystemDiskUsage{}, fmt.Errorf("system df: %w", err)
	}
	return parseSystemDf(output), nil
}

// parseSystemDf converts system df formatted lines into DiskUsageRow values.
func parseSystemDf(output []byte) SystemDiskUsage {
	rows := make([]DiskUsageRow, 0, 4)
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Split(strings.TrimSpace(line), "\t")
		if len(fields) < 3 {
			continue
		}
		typeName := strings.TrimSpace(fields[0])
		if !isSystemDfType(typeName) {
			continue
		}
		sizeLabel := strings.TrimSpace(fields[1])
		reclaimRaw := strings.TrimSpace(fields[2])
		reclaimLabel := reclaimRaw
		if before, _, cut := strings.Cut(reclaimRaw, "("); cut {
			reclaimLabel = strings.TrimSpace(before)
		}
		sizeBytes, _ := utils.ParseDockerHumanSize(sizeLabel)
		if sizeBytes == 0 {
			sizeBytes = parseResourceSize(sizeLabel)
		}
		reclaimBytes, _ := utils.ParseDockerHumanSize(reclaimLabel)
		if reclaimBytes == 0 {
			reclaimBytes = parseResourceSize(reclaimLabel)
		}
		rows = append(rows, DiskUsageRow{
			Type:             typeName,
			Size:             sizeLabel,
			SizeBytes:        sizeBytes,
			Reclaimable:      reclaimLabel,
			ReclaimableBytes: reclaimBytes,
		})
	}
	return SystemDiskUsage{Rows: rows}
}

// ParseSystemDfForTest exposes parseSystemDf for external package tests.
func ParseSystemDfForTest(output []byte) SystemDiskUsage {
	return parseSystemDf(output)
}

// isSystemDfType reports whether typeName is a system df category we surface.
func isSystemDfType(typeName string) bool {
	switch typeName {
	case "Images", "Containers", "Local Volumes", "Build Cache":
		return true
	default:
		return false
	}
}
