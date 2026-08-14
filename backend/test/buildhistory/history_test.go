package buildhistory_test

import (
	"fmt"
	"testing"

	"github.com/enegalan/calf/backend/internal/buildhistory"
)

func TestParseDurationMs(t *testing.T) {
	if got := buildhistory.ParseDurationMs("39.9s"); got < 39900 || got > 40000 {
		t.Fatalf("expected ~39900ms, got %d", got)
	}

	if got := buildhistory.ParseDurationMs("1m 1s"); got < 61000 || got > 62000 {
		t.Fatalf("expected ~61000ms, got %d", got)
	}

	if got := buildhistory.ParseDurationMs("1h5m10s"); got < 3910000 || got > 3920000 {
		t.Fatalf("expected ~3910000ms, got %d", got)
	}
}

func TestIsDockerUnreachablePingEOF(t *testing.T) {
	err := fmt.Errorf(`error during connect: Get "http://%%2FUsers%%2Fegalan%%2F.config%%2Fcalf%%2Fdocker.sock/_ping": EOF`)
	if !buildhistory.IsDockerUnreachable(err) {
		t.Fatal("expected ping EOF to be unreachable")
	}
	if buildhistory.IsDockerUnreachable(fmt.Errorf("image not found")) {
		t.Fatal("image not found must not be unreachable")
	}
}

func TestMergeRowsSkipsDuplicates(t *testing.T) {
	refs := map[string]struct{}{"abc123": {}}
	rows := []buildhistory.Row{
		{Ref: "default/default/abc123", NameLower: "demo"},
		{Ref: "default/default/def456", NameLower: "other"},
	}

	imported := buildhistory.MergeRows(refs, rows)
	if len(imported) != 1 {
		t.Fatalf("expected 1 imported row, got %d", len(imported))
	}
	if imported[0].HistoryID() != "def456" {
		t.Fatalf("unexpected imported id %q", imported[0].HistoryID())
	}
}
