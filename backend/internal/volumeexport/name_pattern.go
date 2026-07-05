package volumeexport

import (
	"strings"
	"time"
)

func HasUniqueNameToken(pattern string) bool {
	pattern = strings.ToLower(strings.TrimSpace(pattern))
	if strings.Contains(pattern, "{timestamp}") || strings.Contains(pattern, "{datetime}") {
		return true
	}

	return strings.Contains(pattern, "{date}") && strings.Contains(pattern, "{time}")
}

func DefaultFileNamePattern(volumeName string) string {
	return "{volume}-{timestamp}.tar.gz"
}

func DefaultImageRefPattern(volumeName string) string {
	return "{volume}-backup:{timestamp}"
}

func ExpandExportNamePattern(pattern, volumeName string, runTime time.Time) string {
	return expandNamePattern(pattern, volumeName, runTime, true)
}

func ExpandExportImageRefPattern(pattern, volumeName string, runTime time.Time) string {
	return expandNamePattern(pattern, volumeName, runTime, false)
}

func expandNamePattern(pattern, volumeName string, runTime time.Time, forFileExport bool) string {
	pattern = strings.TrimSpace(pattern)
	if pattern == "" {
		if forFileExport {
			pattern = DefaultFileNamePattern(volumeName)
		} else {
			pattern = DefaultImageRefPattern(volumeName)
		}
	}

	replacer := strings.NewReplacer(
		"{volume}", sanitizeVolumeToken(volumeName),
		"{timestamp}", runTime.Format("20060102-150405"),
		"{datetime}", runTime.Format("20060102-150405"),
		"{date}", runTime.Format("2006-01-02"),
		"{time}", runTime.Format("15-04-05"),
	)

	expanded := replacer.Replace(pattern)
	if forFileExport {
		return sanitizeExportFileName(expanded)
	}

	return strings.TrimSpace(expanded)
}

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

func sanitizeVolumeToken(value string) string {
	replacer := strings.NewReplacer("/", "_", "\\", "_")
	return replacer.Replace(strings.TrimSpace(value))
}

func sanitizeExportFileName(value string) string {
	replacer := strings.NewReplacer("/", "_", "\\", "_", ":", "-")
	return replacer.Replace(strings.TrimSpace(value))
}
