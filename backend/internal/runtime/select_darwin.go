//go:build darwin

package runtime

// newDarwinRuntime returns the macOS vfkit runtime (the only Darwin engine).
func newDarwinRuntime(vmName, dockerSocket string, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort int, vmKeepAlive bool, proxy ProxyConfig) Runtime {
	return NewVfkit(vmName, dockerSocket, cpus, memoryGB, memorySwapGB, diskGB, apiListenPort, vmKeepAlive, proxy)
}
