package utils

import "strings"

// TrimOutputBytes returns command output with surrounding whitespace removed.
func TrimOutputBytes(output []byte) []byte {
	return []byte(strings.TrimSpace(string(output)))
}
