//go:build !windows

package daemon

import (
	"bufio"
	"os"
	"os/exec"
	goruntime "runtime"
	"strconv"
	"strings"

	"github.com/enegalan/calf/backend/internal/constants"
)

// HostCPUs returns the number of logical CPUs on the host.
func HostCPUs() int {
	return goruntime.NumCPU()
}

// HostMemoryGB returns total host memory in gigabytes, defaulting to 8 when detection is unavailable.
func HostMemoryGB() int {
	bytes, ok := hostMemoryBytes()
	if !ok {
		return constants.DefaultHostMemoryGB
	}
	gb := int(bytes / constants.BytesPerGiB)
	if gb < 1 {
		return 1
	}
	return gb
}

// hostMemoryBytes returns total host memory in bytes for the current platform.
func hostMemoryBytes() (int64, bool) {
	switch goruntime.GOOS {
	case "darwin":
		return darwinHostMemoryBytes()
	case "linux":
		return linuxHostMemoryBytes()
	default:
		return 0, false
	}
}

// darwinHostMemoryBytes reads total memory via sysctl hw.memsize.
func darwinHostMemoryBytes() (int64, bool) {
	out, err := exec.Command("sysctl", "-n", "hw.memsize").Output()
	if err != nil {
		return 0, false
	}
	bytes, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	if err != nil || bytes <= 0 {
		return 0, false
	}
	return bytes, true
}

// linuxHostMemoryBytes reads MemTotal from /proc/meminfo.
func linuxHostMemoryBytes() (int64, bool) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0, false
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "MemTotal:") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			return 0, false
		}
		kb, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil || kb <= 0 {
			return 0, false
		}
		return kb * 1024, true
	}
	if err := scanner.Err(); err != nil {
		return 0, false
	}
	return 0, false
}
