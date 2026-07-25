//go:build !darwin

package runtime

// newDarwinRuntime is unused off darwin; New() never calls it there.
func newDarwinRuntime(vmName, dockerSocket string, cpus, memoryGB, memorySwapGB, diskGB int, diskImage string, apiListenPort int, vmKeepAlive bool, proxy ProxyConfig) Runtime {
	_ = vmName
	_ = cpus
	_ = memoryGB
	_ = memorySwapGB
	_ = diskGB
	_ = diskImage
	_ = apiListenPort
	_ = vmKeepAlive
	_ = proxy
	return NewUnsupported(dockerSocket, "krunkit runtime is only available on macOS")
}
