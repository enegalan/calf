//go:build !darwin

package runtime

// newDarwinRuntime is unused off darwin; New() never calls it there.
func newDarwinRuntime(vmName, dockerSocket string, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort int, vmKeepAlive bool, proxy ProxyConfig) Runtime {
	return NewLima(vmName, dockerSocket, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort, vmKeepAlive, proxy)
}
