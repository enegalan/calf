package utils

import "strings"

// SanitizeFileName replaces path separators in a name so it is safe for staging file paths.
func SanitizeFileName(name string) string {
	replacer := strings.NewReplacer("/", "_", ":", "_", "\\", "_")
	return replacer.Replace(name)
}

// SanitizeExportFileName replaces characters that are unsafe in export file names.
func SanitizeExportFileName(value string) string {
	replacer := strings.NewReplacer("/", "_", "\\", "_", ":", "-")
	return replacer.Replace(strings.TrimSpace(value))
}
