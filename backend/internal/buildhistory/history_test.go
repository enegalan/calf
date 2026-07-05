package buildhistory

import (
	"testing"
)

func TestParseDurationMs(t *testing.T) {
	if got := ParseDurationMs("39.9s"); got < 39900 || got > 40000 {
		t.Fatalf("expected ~39900ms, got %d", got)
	}

	if got := ParseDurationMs("1m 1s"); got < 61000 || got > 62000 {
		t.Fatalf("expected ~61000ms, got %d", got)
	}

	if got := ParseDurationMs("1h5m10s"); got < 3910000 || got > 3920000 {
		t.Fatalf("expected ~3910000ms, got %d", got)
	}
}

func TestMergeRowsSkipsDuplicates(t *testing.T) {
	refs := map[string]struct{}{"abc123": {}}
	rows := []Row{
		{Ref: "default/default/abc123", NameLower: "demo"},
		{Ref: "default/default/def456", NameLower: "other"},
	}

	imported := MergeRows(refs, rows)
	if len(imported) != 1 {
		t.Fatalf("expected 1 imported row, got %d", len(imported))
	}
	if imported[0].HistoryID() != "def456" {
		t.Fatalf("unexpected imported id %q", imported[0].HistoryID())
	}
}

func TestParseBuildxHistoryJSON(t *testing.T) {
	rows := parseRows([]byte(`{"cached_steps":1,"completed_at":"2026-07-04T01:10:03.861183581Z","completed_steps":5,"created_at":"2026-07-04T01:10:03.808406711Z","name":"p2p-lan-p2p-lan","ref":"default/default/szzsnkdslb4c2ees6aok7xln6","status":"Completed","total_steps":5}`))
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}

	row := rows[0]
	if row.BuildName() != "p2p-lan-p2p-lan" {
		t.Fatalf("unexpected name %q", row.BuildName())
	}
	if row.HistoryID() != "szzsnkdslb4c2ees6aok7xln6" {
		t.Fatalf("unexpected history id %q", row.HistoryID())
	}
	if row.CachedSteps != 1 || row.TotalSteps != 5 {
		t.Fatalf("unexpected step counts")
	}
	if row.BuildDurationMs() <= 0 {
		t.Fatalf("expected positive duration")
	}
}
