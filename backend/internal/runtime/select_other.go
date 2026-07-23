//go:build !darwin

package runtime

// newDarwinRuntime is unused off darwin; New() never calls it there.
func newDarwinRuntime(vmName, dockerSocket string, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort int, vmKeepAlive bool, proxy ProxyConfig) Runtime {
	_ = vmName
	_ = cpus
	_ = memoryGB
	_ = memorySwapGB
	_ = diskGB
	_ = apiListenPort
	_ = vmKeepAlive
	_ = proxy
	return NewUnsupported(dockerSocket, "krunkit runtime is only available on macOS")
}
