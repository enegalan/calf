package runtime_test

import (
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestParseNetworkLines(t *testing.T) {
	output := []byte(`{"ID":"9d1ce4c80488","Name":"bridge","Driver":"bridge"}
{"ID":"a1b2c3d4e5f6","Name":"p2p-lan_local_dev","Driver":"bridge"}
{"Name":"host","Driver":"host"}
{"Name":"none","Driver":"null"}`)

	networks, err := runtime.ParseNetworkLines(output)
	if err != nil {
		t.Fatalf("ParseNetworkLines() error: %v", err)
	}

	if len(networks) != 2 {
		t.Fatalf("expected 2 networks, got %d", len(networks))
	}

	if networks[0].Name != "bridge" || networks[0].ID != "9d1ce4c80488" {
		t.Fatalf("unexpected first network: %+v", networks[0])
	}

	if networks[0].Driver != "bridge" || networks[0].Scope != "local" {
		t.Fatalf("expected driver bridge and scope local, got %+v", networks[0])
	}
}

func TestIsPseudoNetwork(t *testing.T) {
	for _, name := range []string{"host", "none", "null", "HOST", " None "} {
		if !runtime.IsPseudoNetwork(name) {
			t.Fatalf("expected %q to be pseudo network", name)
		}
	}

	if runtime.IsPseudoNetwork("bridge") {
		t.Fatal("expected bridge not to be pseudo network")
	}
}
