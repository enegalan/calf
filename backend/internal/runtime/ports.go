package runtime

import (
	"regexp"
	"strconv"
)

// hostTCPPortPattern is a regular expression for matching host TCP port numbers.
var hostTCPPortPattern = regexp.MustCompile(`:(\d+)->\d+/tcp`)

// ExtractHostTCPPort returns the first host TCP port from a nerdctl/docker ports string.
func ExtractHostTCPPort(ports string) string {
	match := hostTCPPortPattern.FindStringSubmatch(ports)
	if len(match) < 2 {
		return ""
	}

	return match[1]
}

// ParsePublishedTCPPorts parses nerdctl port mappings into host TCP port numbers.
func ParsePublishedTCPPorts(value string) map[int]struct{} {
	ports := make(map[int]struct{})

	for _, match := range hostTCPPortPattern.FindAllStringSubmatch(value, -1) {
		port, err := strconv.Atoi(match[1])
		if err != nil || port <= 0 {
			continue
		}

		ports[port] = struct{}{}
	}

	return ports
}
