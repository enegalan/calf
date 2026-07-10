package volumeexport

import (
	"strings"
	"time"
)

// HasUniqueNameToken reports whether pattern includes tokens that make each expanded name unique.
func HasUniqueNameToken(pattern string) bool {
	pattern = strings.ToLower(strings.TrimSpace(pattern))
	if strings.Contains(pattern, "{timestamp}") || strings.Contains(pattern, "{datetime}") {
		return true
	}

	return strings.Contains(pattern, "{date}") && strings.Contains(pattern, "{time}")
}

// DefaultFileNamePattern returns the default local-file export name pattern for volumeName.
func DefaultFileNamePattern(volumeName string) string {
	return "{volume}-{timestamp}.tar.gz"
}

// DefaultImageRefPattern returns the default image export reference pattern for volumeName.
func DefaultImageRefPattern(volumeName string) string {
	return "{volume}-backup:{timestamp}"
}

// ExpandExportNamePattern substitutes tokens in pattern and sanitizes the result as a file name.
func ExpandExportNamePattern(pattern, volumeName string, runTime time.Time) string {
	return expandNamePattern(pattern, volumeName, runTime, true)
}

// ExpandExportImageRefPattern substitutes tokens in pattern and normalizes the result as an image reference.
func ExpandExportImageRefPattern(pattern, volumeName string, runTime time.Time) string {
	return expandNamePattern(pattern, volumeName, runTime, false)
}

// expandNamePattern substitutes volume and time tokens, applying file- or image-specific defaults and normalization.
func expandNamePattern(pattern, volumeName string, runTime time.Time, forFileExport bool) string {
	pattern = strings.TrimSpace(pattern)
	if pattern == "" {
		if forFileExport {
			pattern = DefaultFileNamePattern(volumeName)
		} else {
			pattern = DefaultImageRefPattern(volumeName)
		}
	}

	volumeToken := sanitizeVolumeToken(volumeName)
	if !forFileExport {
		volumeToken = strings.ToLower(volumeToken)
	}

	replacer := strings.NewReplacer(
		"{volume}", volumeToken,
		"{timestamp}", runTime.Format("20060102-150405"),
		"{datetime}", runTime.Format("20060102-150405"),
		"{date}", runTime.Format("2006-01-02"),
		"{time}", runTime.Format("15-04-05"),
	)

	expanded := replacer.Replace(pattern)
	if forFileExport {
		return SanitizeExportFileName(expanded)
	}

	return strings.ToLower(strings.TrimSpace(expanded))
}

// ResolveScheduledExportNames expands file and image names for a scheduled export at runTime.
func ResolveScheduledExportNames(schedule Schedule, runTime time.Time) (fileName, imageRef string) {
	switch strings.TrimSpace(schedule.Type) {
	case TypeLocalFile:
		pattern := schedule.FileName
		if strings.TrimSpace(pattern) == "" {
			pattern = DefaultFileNamePattern(schedule.Volume)
		}

		return ExpandExportNamePattern(pattern, schedule.Volume, runTime), ""
	case TypeLocalImage:
		return "", schedule.ImageRef
	case TypeNewImage, TypeRegistry:
		pattern := schedule.ImageRef
		if strings.TrimSpace(pattern) == "" {
			pattern = DefaultImageRefPattern(schedule.Volume)
		}

		return "", ExpandExportImageRefPattern(pattern, schedule.Volume, runTime)
	default:
		return "", ""
	}
}

// sanitizeVolumeToken replaces path separators in a volume name for use in name patterns.
func sanitizeVolumeToken(value string) string {
	replacer := strings.NewReplacer("/", "_", "\\", "_")
	return replacer.Replace(strings.TrimSpace(value))
}

// SanitizeExportFileName replaces characters that are unsafe in file names.
func SanitizeExportFileName(value string) string {
	replacer := strings.NewReplacer("/", "_", "\\", "_", ":", "-")
	return replacer.Replace(strings.TrimSpace(value))
}
