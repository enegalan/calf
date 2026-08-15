package runtime

import (
	"strings"
)

// CollectEmptyNameContainerIDs returns container IDs from `docker ps` lines formatted as
// "ID\tNames" (or "ID Names") whose name field is empty. Empty names are the signature of
// corrupt engine leftovers that appear in `ps` but fail `inspect`/`rm`.
func CollectEmptyNameContainerIDs(psOutput string) []string {
	ids := make([]string, 0)
	seen := make(map[string]struct{})
	for _, line := range strings.Split(psOutput, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		id, name, ok := strings.Cut(line, "\t")
		if !ok {
			fields := strings.Fields(line)
			if len(fields) == 0 {
				continue
			}
			id = fields[0]
			name = ""
			if len(fields) > 1 {
				name = fields[1]
			}
		}
		id = strings.TrimSpace(id)
		if !isDockerContainerID(id) || strings.TrimSpace(name) != "" {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
	}
	return ids
}

// isDockerContainerID reports whether s looks like a docker container id (hex, 12–64 chars).
func isDockerContainerID(s string) bool {
	if n := len(s); n < 12 || n > 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') && (c < 'A' || c > 'F') {
			return false
		}
	}
	return true
}

// isNoSuchContainerError reports whether err is a docker "No such container" failure.
func isNoSuchContainerError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "no such container") || strings.Contains(msg, "no such object")
}

// CorruptContainerWipeScript builds a guest root script that deletes docker metadata dirs
// for corrupt IDs and schedules a deferred docker/containerd restart.
func CorruptContainerWipeScript(ids []string) string {
	var script strings.Builder
	script.WriteString("set +e\n")
	for _, id := range ids {
		if !isDockerContainerID(id) {
			continue
		}
		script.WriteString("rm -rf /var/lib/docker/containers/")
		script.WriteString(id)
		script.WriteString(" /var/lib/docker/containers/")
		script.WriteString(id)
		script.WriteString("*\n")
		script.WriteString("ctr -n moby tasks delete -f ")
		script.WriteString(id)
		script.WriteString(" >/dev/null 2>&1\n")
		script.WriteString("ctr -n moby containers delete ")
		script.WriteString(id)
		script.WriteString(" >/dev/null 2>&1\n")
	}
	script.WriteString("systemctl daemon-reload >/dev/null 2>&1\n")
	script.WriteString("systemd-run --quiet --collect --on-active=1s --timer-property=AccuracySec=1s /bin/systemctl try-restart containerd.service docker.service\n")
	return script.String()
}
