//go:build darwin

package runtime

// newDarwinRuntime returns the macOS container engine (krunkit + gvproxy).
func newDarwinRuntime(vmName, dockerSocket string, cpus, memoryGB, memorySwapGB, diskGB int, diskImage string, apiListenPort int, vmKeepAlive bool, proxy ProxyConfig) Runtime {
	return NewKrunkit(vmName, dockerSocket, cpus, memoryGB, memorySwapGB, diskGB, diskImage, apiListenPort, vmKeepAlive, proxy)
}
