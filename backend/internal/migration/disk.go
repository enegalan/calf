package migration

import (
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

const migrationHeadroomBytes = 2 * 1024 * 1024 * 1024

// checkMigrationDiskSpace verifies the Lima VM has enough free space for the estimated migration size.
func checkMigrationDiskSpace(ctx context.Context, vmName, ddSocket string) error {
	if vmName == "" {
		vmName = "calf"
	}

	required, err := estimateMigrationBytes(ctx, ddSocket)
	if err != nil {
		return fmt.Errorf("estimate migration size: %w", err)
	}

	free, err := vmFreeBytes(ctx, vmName)
	if err != nil {
		return fmt.Errorf("check VM disk space: %w", err)
	}

	if free >= required {
		return nil
	}

	recommendedGiB := bytesToGiB(required) + 10
	return fmt.Errorf(
		"VM has %s free but migration needs ~%s. Set disk_gb to at least %d in config, run limactl delete %s, and restart the backend",
		formatBytes(free),
		formatBytes(required),
		recommendedGiB,
		vmName,
	)
}

// estimateMigrationBytes sums Docker Desktop image, volume, and container usage plus migration headroom.
func estimateMigrationBytes(ctx context.Context, ddSocket string) (int64, error) {
	output, err := runDocker(ctx, ddSocket, "system", "df", "--format", "{{.Type}}\t{{.Size}}")
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
			size, err := parseHumanSize(fields[1])
			if err != nil {
				return 0, err
			}
			total += size
		}
	}

	return total + migrationHeadroomBytes, nil
}

// vmFreeBytes reads available root filesystem bytes inside the Lima VM.
func vmFreeBytes(ctx context.Context, vmName string) (int64, error) {
	output, err := runInVM(ctx, vmName, "df", "-B1", "--output=avail", "/")
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

// runInVM executes a command inside the named Lima VM via limactl shell.
func runInVM(ctx context.Context, vmName string, args ...string) ([]byte, error) {
	shellArgs := append([]string{"shell", vmName, "--"}, args...)
	command := exec.CommandContext(ctx, "limactl", shellArgs...)

	var stdout strings.Builder
	var stderr strings.Builder
	command.Stdout = &stdout
	command.Stderr = &stderr

	if err := command.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = strings.TrimSpace(stdout.String())
		}
		return nil, fmt.Errorf("limactl %s: %w: %s", strings.Join(shellArgs, " "), err, msg)
	}

	return []byte(stdout.String()), nil
}

// parseHumanSize converts Docker CLI human-readable size strings such as "1.2GB" to bytes.
func parseHumanSize(value string) (int64, error) {
	value = strings.TrimSpace(value)
	if value == "" || value == "0" || value == "0B" {
		return 0, nil
	}

	units := []struct {
		suffix string
		mult   int64
	}{
		{"GB", 1024 * 1024 * 1024},
		{"MB", 1024 * 1024},
		{"KB", 1024},
		{"B", 1},
	}

	for _, unit := range units {
		if strings.HasSuffix(value, unit.suffix) {
			number := strings.TrimSpace(strings.TrimSuffix(value, unit.suffix))
			parsed, err := strconv.ParseFloat(number, 64)
			if err != nil {
				return 0, fmt.Errorf("parse size %q: %w", value, err)
			}

			return int64(parsed * float64(unit.mult)), nil
		}
	}

	return 0, fmt.Errorf("unknown size format %q", value)
}

// formatBytes renders a byte count as a short GB or MB string for error messages.
func formatBytes(bytes int64) string {
	const gib = 1024 * 1024 * 1024
	if bytes >= gib {
		return fmt.Sprintf("%.1f GB", float64(bytes)/float64(gib))
	}

	const mib = 1024 * 1024
	return fmt.Sprintf("%.0f MB", float64(bytes)/float64(mib))
}

// bytesToGiB rounds a byte count up to the next whole gibibyte.
func bytesToGiB(bytes int64) int {
	const gib = 1024 * 1024 * 1024
	return int((bytes + gib - 1) / gib)
}
