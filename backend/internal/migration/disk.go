package migration

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/dockerexec"
	"github.com/enegalan/calf/backend/internal/utils"
)

// checkMigrationDiskSpace verifies the Calf engine has enough free space for the estimated migration size.
func checkMigrationDiskSpace(ctx context.Context, calfSocket, ddSocket string) error {
	required, err := estimateMigrationBytes(ctx, ddSocket)
	if err != nil {
		return fmt.Errorf("estimate migration size: %w", err)
	}

	free, err := engineFreeBytes(ctx, calfSocket)
	if err != nil {
		return fmt.Errorf("check engine disk space: %w", err)
	}

	if free >= required {
		return nil
	}

	recommendedGiB := bytesToGiB(required) + 10
	return fmt.Errorf(
		"engine has %s free but migration needs ~%s (~%d GiB recommended). Free space in the guest or rebuild the vfkit disk (make guest-vfkit), then retry",
		utils.FormatBytes(free),
		utils.FormatBytes(required),
		recommendedGiB,
	)
}

// estimateMigrationBytes sums Docker Desktop image, volume, and container usage plus migration headroom.
func estimateMigrationBytes(ctx context.Context, ddSocket string) (int64, error) {
	output, err := dockerexec.Run(ctx, ddSocket, "system", "df", "--format", "{{.Type}}\t{{.Size}}")
	if err != nil {
		return 0, err
	}

	var total int64
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Split(strings.TrimSpace(line), "\t")
		if len(fields) != 2 {
			continue
		}

		switch fields[0] {
		case "Images", "Local Volumes", "Containers":
			size, err := utils.ParseDockerHumanSize(fields[1])
			if err != nil {
				return 0, err
			}
			total += size
		}
	}

	return total + constants.MigrationHeadroomBytes, nil
}

// engineFreeBytes reads available root filesystem bytes inside the Calf engine (via a one-shot container).
func engineFreeBytes(ctx context.Context, calfSocket string) (int64, error) {
	output, err := dockerexec.Run(ctx, calfSocket, "run", "--rm", "--privileged", constants.AlpineSmokeImage,
		"sh", "-c", "df -B1 / | awk 'NR==2 {print $4}'")
	if err != nil {
		return 0, err
	}

	return parseAvailBytes(output)
}

// parseAvailBytes extracts the numeric Avail column from df output.
func parseAvailBytes(output []byte) (int64, error) {
	for _, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.EqualFold(line, "Avail") {
			continue
		}

		avail, err := strconv.ParseInt(line, 10, 64)
		if err == nil {
			return avail, nil
		}
	}

	return 0, fmt.Errorf("parse df output: %q", strings.TrimSpace(string(output)))
}

// bytesToGiB rounds a byte count up to the next whole gibibyte.
func bytesToGiB(bytes int64) int {
	return int((bytes + constants.BytesPerGiB - 1) / constants.BytesPerGiB)
}
