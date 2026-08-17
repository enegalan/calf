package runtime

import (
	"encoding/json"
	"fmt"
	"strings"
)

// MergeDaemonJSON overlays user JSON onto the baked guest daemon.json (buildkit + DNS).
func MergeDaemonJSON(overlay string, dockerSubnet string) (string, error) {
	base := map[string]any{
		"features": map[string]any{"buildkit": true},
		"dns":      []any{"1.1.1.1", "8.8.8.8"},
	}
	overlay = strings.TrimSpace(overlay)
	if overlay != "" {
		var extra map[string]any
		if err := json.Unmarshal([]byte(overlay), &extra); err != nil {
			return "", fmt.Errorf("daemon.json: %w", err)
		}
		for key, value := range extra {
			base[key] = value
		}
	}
	subnet := strings.TrimSpace(dockerSubnet)
	if subnet != "" {
		base["bip"] = subnet
	}
	out, err := json.MarshalIndent(base, "", "  ")
	if err != nil {
		return "", err
	}
	return string(out) + "\n", nil
}
