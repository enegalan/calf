package utils

import "strings"

func ParseLines(output []byte, keep func(string) bool) []string {
	items := make([]string, 0)
	for _, line := range strings.Split(string(output), "\n") {
		item := strings.TrimSpace(line)
		if item == "" {
			continue
		}

		if keep != nil && !keep(item) {
			continue
		}

		items = append(items, item)
	}

	return items
}
