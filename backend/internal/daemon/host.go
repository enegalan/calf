package daemon

import (
	"os/exec"
	goruntime "runtime"
	"strconv"
	"strings"
)

// HostCPUs returns the number of logical CPUs on the host.
func HostCPUs() int {
	return goruntime.NumCPU()
}

// HostMemoryGB returns total host memory in gigabytes, defaulting to 8 when sysctl is unavailable.
func HostMemoryGB() int {
	out, err := exec.Command("sysctl", "-n", "hw.memsize").Output()
	if err != nil {
		return 8
	}
	bytes, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	if err != nil {
		return 8
	}
	gb := int(bytes / (1024 * 1024 * 1024))
	if gb < 1 {
		return 1
	}
	return gb
}
