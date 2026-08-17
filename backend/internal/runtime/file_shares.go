package runtime

import (
	"fmt"
	"path/filepath"
	"strings"
)

// FileShareSpec is one extra virtiofs share beyond calf-home and calf-mounts.
type FileShareSpec struct {
	HostPath   string
	Tag        string
	GuestMount string
}

// ExtraFileShareSpecs filters extra host dirs that are not already covered by $HOME.
func ExtraFileShareSpecs(home string, shares []string) []FileShareSpec {
	home = filepath.Clean(strings.TrimSpace(home))
	seen := make(map[string]struct{})
	out := make([]FileShareSpec, 0, len(shares))
	index := 0
	for _, raw := range shares {
		path := filepath.Clean(strings.TrimSpace(raw))
		if path == "" || path == "." || !filepath.IsAbs(path) {
			continue
		}
		if _, ok := seen[path]; ok {
			continue
		}
		if home != "" && (path == home || strings.HasPrefix(path, home+string(filepath.Separator))) {
			continue
		}
		seen[path] = struct{}{}
		out = append(out, FileShareSpec{
			HostPath:   path,
			Tag:        fmt.Sprintf("calf-share-%d", index),
			GuestMount: fmt.Sprintf("/mnt/calf-share/%d", index),
		})
		index++
	}
	return out
}

// ExtraShareGuestScript mounts extra virtiofs tags and bind-mounts them at the host path in the guest.
func ExtraShareGuestScript(specs []FileShareSpec) string {
	if len(specs) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("set -e\n")
	for _, spec := range specs {
		tag := strings.ReplaceAll(spec.Tag, "'", `'\''`)
		mount := strings.ReplaceAll(spec.GuestMount, "'", `'\''`)
		host := strings.ReplaceAll(spec.HostPath, "'", `'\''`)
		b.WriteString("mkdir -p '" + mount + "'\n")
		b.WriteString("if ! mountpoint -q '" + mount + "' 2>/dev/null; then\n")
		b.WriteString("  mount -t virtiofs -o noatime '" + tag + "' '" + mount + "' || echo extra share " + tag + " failed >&2\n")
		b.WriteString("fi\n")
		b.WriteString("mkdir -p '" + host + "'\n")
		b.WriteString("if ! mountpoint -q '" + host + "' 2>/dev/null; then\n")
		b.WriteString("  mount --bind '" + mount + "' '" + host + "' || ln -sfn '" + mount + "' '" + host + "'\n")
		b.WriteString("fi\n")
	}
	return b.String()
}
