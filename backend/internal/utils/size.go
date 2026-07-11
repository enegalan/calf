package utils

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/enegalan/calf/backend/internal/constants"
)

// ParseDockerHumanSize converts Docker CLI human-readable size strings such as "1.2GB" to bytes.
func ParseDockerHumanSize(value string) (int64, error) {
	value = strings.TrimSpace(value)
	if value == "" || value == "0" || value == "0B" {
		return 0, nil
	}

	units := []struct {
		suffix string
		mult   int64
	}{
		{"GB", constants.BytesPerGiB},
		{"MB", constants.BytesPerMiB},
		{"KB", constants.BytesPerKiB},
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
