package runtime

import (
	"fmt"
	"io"
	"net"
	"os/exec"
	goruntime "runtime"
	"strconv"
	"strings"
	"sync"
)

// localhostProxies represents the localhost proxies for the runtime.
type localhostProxies struct {
	mu        sync.Mutex
	listeners map[int]net.Listener
	conflicts map[int]PortConflict
	reserved  map[int]struct{}
}

// newLocalhostProxies returns nil on non-macOS. Lima forwards container ports
// to 127.0.0.1 inside the VM, but many clients bind [::1] on the host; the
// proxy listens on ::1 and forwards to 127.0.0.1 so both addresses work.
func newLocalhostProxies() *localhostProxies {
	if goruntime.GOOS != "darwin" {
		return nil
	}

	return &localhostProxies{
		listeners: make(map[int]net.Listener),
		conflicts: make(map[int]PortConflict),
		reserved:  make(map[int]struct{}),
	}
}

// ParseListenPort extracts the TCP port number from a host:port listen address.
func ParseListenPort(addr string) int {
	_, portValue, err := net.SplitHostPort(addr)
	if err != nil {
		return 0
	}

	port, err := strconv.Atoi(portValue)
	if err != nil || port <= 0 {
		return 0
	}

	return port
}

// setReservedPorts marks ports that must not get a localhost proxy listener.
func (p *localhostProxies) setReservedPorts(ports ...int) {
	if p == nil {
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	p.reserved = make(map[int]struct{}, len(ports))
	for _, port := range ports {
		if port > 0 {
			p.reserved[port] = struct{}{}
		}
	}
}

// conflictsSnapshot returns a copy of detected localhost port conflicts.
func (p *localhostProxies) conflictsSnapshot() []PortConflict {
	if p == nil {
		return nil
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	if len(p.conflicts) == 0 {
		return nil
	}

	items := make([]PortConflict, 0, len(p.conflicts))
	for _, conflict := range p.conflicts {
		items = append(items, conflict)
	}

	return items
}

// stopAll closes every proxy listener and clears conflict state.
func (p *localhostProxies) stopAll() {
	if p == nil {
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	for port, listener := range p.listeners {
		_ = listener.Close()
		delete(p.listeners, port)
	}

	p.conflicts = make(map[int]PortConflict)
}

// sync starts, stops, or rebuilds ::1 proxies to match the desired published ports.
func (p *localhostProxies) sync(ports map[int]struct{}, force bool) {
	if p == nil {
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	if force {
		for port, listener := range p.listeners {
			_ = listener.Close()
			delete(p.listeners, port)
		}
		p.conflicts = make(map[int]PortConflict)
	}

	for port, listener := range p.listeners {
		if _, ok := ports[port]; ok {
			continue
		}

		_ = listener.Close()
		delete(p.listeners, port)
		delete(p.conflicts, port)
	}

	for port := range ports {
		if _, reserved := p.reserved[port]; reserved {
			if listener, ok := p.listeners[port]; ok {
				_ = listener.Close()
				delete(p.listeners, port)
			}
			delete(p.conflicts, port)
			continue
		}

		if _, ok := p.listeners[port]; ok {
			delete(p.conflicts, port)
			continue
		}

		listener, err := net.Listen("tcp", net.JoinHostPort("::1", strconv.Itoa(port)))
		if err != nil {
			p.conflicts[port] = localhostPortConflict(port)
			continue
		}

		delete(p.conflicts, port)
		p.listeners[port] = listener
		go p.serve(listener, port)
	}
}

// serve accepts connections on listener and forwards them to 127.0.0.1:port.
func (p *localhostProxies) serve(listener net.Listener, port int) {
	target := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))

	for {
		client, err := listener.Accept()
		if err != nil {
			p.mu.Lock()
			if current, ok := p.listeners[port]; ok && current == listener {
				delete(p.listeners, port)
			}
			p.mu.Unlock()
			return
		}

		go proxyTCPConnection(client, target)
	}
}

// proxyTCPConnection bidirectionally copies bytes between client and target.
func proxyTCPConnection(client net.Conn, target string) {
	server, err := net.Dial("tcp", target)
	if err != nil {
		_ = client.Close()
		return
	}

	go func() {
		_, _ = io.Copy(server, client)
		_ = server.Close()
	}()

	_, _ = io.Copy(client, server)
	_ = client.Close()
	_ = server.Close()
}

// publishedTCPPorts collects host TCP ports published by running containers.
func publishedTCPPorts(containers []Container) map[int]struct{} {
	ports := make(map[int]struct{})

	for _, container := range containers {
		if !containerIsRunning(container) {
			continue
		}

		for port := range ParsePublishedTCPPorts(container.Ports) {
			ports[port] = struct{}{}
		}
	}

	return ports
}

// containerIsRunning reports whether a container is in a running state.
func containerIsRunning(container Container) bool {
	state := strings.ToLower(strings.TrimSpace(container.State))
	if state == "running" {
		return true
	}

	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(container.Status)), "up")
}

// localhostPortConflict builds a PortConflict for a port that cannot be proxied.
func localhostPortConflict(port int) PortConflict {
	process := findLocalhostPortBlocker(port)
	hint := fmt.Sprintf("localhost:%d is used by %s; stop that process or container so Calf can forward the port.", port, process)

	return PortConflict{
		Port:    port,
		Process: process,
		Hint:    hint,
	}
}

// findLocalhostPortBlocker identifies the process listening on a host port via lsof.
func findLocalhostPortBlocker(port int) string {
	output, err := exec.Command("lsof", "-nP", "-iTCP:"+strconv.Itoa(port), "-sTCP:LISTEN").Output()
	if err != nil {
		return "another process"
	}

	portSuffix := ":" + strconv.Itoa(port)
	for _, line := range strings.Split(string(output), "\n") {
		if strings.HasPrefix(line, "COMMAND") || line == "" {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) < 9 {
			continue
		}

		address := fields[len(fields)-1]
		if !strings.HasSuffix(address, portSuffix) && !strings.Contains(address, portSuffix) {
			continue
		}

		if strings.HasPrefix(address, "127.0.0.1:") {
			continue
		}

		return fields[0]
	}

	return "another process"
}
