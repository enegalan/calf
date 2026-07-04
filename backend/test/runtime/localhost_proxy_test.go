package runtime_test

import (
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestParsePublishedTCPPorts(t *testing.T) {
	ports := runtime.ParsePublishedTCPPorts(`0.0.0.0:3030->3030/tcp, [::]:3478->3478/udp, 0.0.0.0:8080->80/tcp`)

	if len(ports) != 2 {
		t.Fatalf("expected 2 TCP ports, got %d (%v)", len(ports), ports)
	}

	if _, ok := ports[3030]; !ok {
		t.Fatalf("expected port 3030, got %v", ports)
	}

	if _, ok := ports[8080]; !ok {
		t.Fatalf("expected port 8080, got %v", ports)
	}

	if _, ok := ports[3478]; ok {
		t.Fatalf("did not expect UDP port 3478, got %v", ports)
	}
}

func TestParseListenPort(t *testing.T) {
	if got := runtime.ParseListenPort(":8765"); got != 8765 {
		t.Fatalf("expected 8765, got %d", got)
	}

	if got := runtime.ParseListenPort("127.0.0.1:8765"); got != 8765 {
		t.Fatalf("expected 8765, got %d", got)
	}

	if got := runtime.ParseListenPort("invalid"); got != 0 {
		t.Fatalf("expected 0 for invalid addr, got %d", got)
	}
}
