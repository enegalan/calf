package runtime

import (
	"fmt"
	"io"
	"net"
	"os/exec"
	"regexp"
	goruntime "runtime"
	"strconv"
	"strings"
	"sync"
)

type localhostProxies struct {
	mu        sync.Mutex
	listeners map[int]net.Listener
	conflicts map[int]PortConflict
	reserved  map[int]struct{}
}

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

func publishedTCPPorts(containers []Container) map[int]struct{} {
	ports := make(map[int]struct{})

	for _, container := range containers {
		if !containerIsRunning(container) {
			continue
		}

		for port := range parsePublishedTCPPorts(container.Ports) {
			ports[port] = struct{}{}
		}
	}

	return ports
}

func containerIsRunning(container Container) bool {
	state := strings.ToLower(strings.TrimSpace(container.State))
	if state == "running" {
		return true
	}

	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(container.Status)), "up")
}

var publishedTCPPortPattern = regexp.MustCompile(`:(\d+)->\d+/tcp`)

func ParsePublishedTCPPorts(value string) map[int]struct{} {
	return parsePublishedTCPPorts(value)
}

func parsePublishedTCPPorts(value string) map[int]struct{} {
	ports := make(map[int]struct{})

	for _, match := range publishedTCPPortPattern.FindAllStringSubmatch(value, -1) {
		port, err := strconv.Atoi(match[1])
		if err != nil || port <= 0 {
			continue
		}

		ports[port] = struct{}{}
	}

	return ports
}

func localhostPortConflict(port int) PortConflict {
	process := findLocalhostPortBlocker(port)
	hint := fmt.Sprintf("localhost:%d is used by %s; stop that process or container so Calf can forward the port.", port, process)

	return PortConflict{
		Port:    port,
		Process: process,
		Hint:    hint,
	}
}

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
