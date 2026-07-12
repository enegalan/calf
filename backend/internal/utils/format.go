package utils

import "fmt"

// FormatBytes renders a byte count as a human-readable size string.
func FormatBytes(size int64) string {
	if size <= 0 {
		return "0 B"
	}

	const unit = 1024
	if size < unit {
		return fmt.Sprintf("%d B", size)
	}

	div, exp := int64(unit), 0
	for numerator := size / unit; numerator >= unit; numerator /= unit {
		div *= unit
		exp++
	}

	value := float64(size) / float64(div)
	suffix := []string{"KB", "MB", "GB", "TB"}[exp]
	return fmt.Sprintf("%.1f %s", value, suffix)
}
