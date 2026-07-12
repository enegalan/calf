//go:build windows

package daemon

import (
	goruntime "runtime"
	"unsafe"

	"github.com/enegalan/calf/backend/internal/constants"
	"golang.org/x/sys/windows"
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

type windowsMemoryStatusEx struct {
	length               uint32
	memoryLoad           uint32
	totalPhys            uint64
	availPhys            uint64
	totalPageFile        uint64
	availPageFile        uint64
	totalVirtual         uint64
	availVirtual         uint64
	availExtendedVirtual uint64
}

var procGlobalMemoryStatusEx = windows.NewLazySystemDLL("kernel32.dll").NewProc("GlobalMemoryStatusEx")

// hostMemoryBytes returns total host memory in bytes via GlobalMemoryStatusEx.
func hostMemoryBytes() (int64, bool) {
	var status windowsMemoryStatusEx
	status.length = uint32(unsafe.Sizeof(status))
	ret, _, _ := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&status)))
	if ret == 0 {
		return 0, false
	}
	if status.totalPhys <= 0 {
		return 0, false
	}
	return int64(status.totalPhys), true
}
