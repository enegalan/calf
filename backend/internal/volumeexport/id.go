package volumeexport

import (
	"fmt"
	"time"
)

// newResourceID generates a unique identifier scoped to a volume name.
func newResourceID(prefix, volumeName string) string {
	name := sanitizeName(volumeName)
	if prefix == "" {
		return fmt.Sprintf("%s-%d", name, time.Now().UnixNano())
	}

	return fmt.Sprintf("%s-%s-%d", prefix, name, time.Now().UnixNano())
}
