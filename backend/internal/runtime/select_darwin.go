//go:build darwin

package runtime

import (
	"os"
	"strings"

	"github.com/enegalan/calf/backend/internal/constants"
)

// newDarwinRuntime picks vfkit when ready (or forced), otherwise Lima.
// CALF_RUNTIME=lima forces Lima; CALF_RUNTIME=vfkit forces vfkit; unset/auto prefers vfkit when
// a local disk/seed exists, or when vfkit is bundled next to calf-daemon (first-run download).
func newDarwinRuntime(vmName, dockerSocket string, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort int, vmKeepAlive bool, proxy ProxyConfig) Runtime {
	choice := strings.ToLower(strings.TrimSpace(os.Getenv("CALF_RUNTIME")))
	switch choice {
	case "lima":
		return NewLima(vmName, dockerSocket, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort, vmKeepAlive, proxy)
	case "vfkit":
		return NewVfkit(vmName, dockerSocket, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort, vmKeepAlive, proxy)
	default:
		if vfkitReady(vmName) {
			return NewVfkit(vmName, dockerSocket, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort, vmKeepAlive, proxy)
		}
		return NewLima(vmName, dockerSocket, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort, vmKeepAlive, proxy)
	}
}

// vfkitReady reports whether the vfkit engine should be preferred on this Mac.
func vfkitReady(vmName string) bool {
	bin := resolveVfkitBinary()
	if bin == "" {
		return false
	}
	if vmName == "" {
		vmName = constants.DefaultVMName
	}
	if localDiskOrSeed(vmName) {
		return true
	}
	// App-bundled vfkit: allow first-run download of the guest disk from GitHub Releases.
	return isBundledVfkit(bin) && os.Getenv("CALF_VFKIT_NO_DOWNLOAD") != "1"
}
