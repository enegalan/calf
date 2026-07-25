package runtime_test

import (
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestParseSystemDf(t *testing.T) {
	input := []byte("Images\t1.402GB\t793.8MB (56%)\n" +
		"Containers\t98.3kB\t98.3kB (100%)\n" +
		"Local Volumes\t1.2GB\t400MB (33%)\n" +
		"Build Cache\t500MB\t500MB\n" +
		"Other\t1MB\t1MB\n")

	usage := runtime.ParseSystemDfForTest(input)
	if len(usage.Rows) != 4 {
		t.Fatalf("expected 4 rows, got %d: %+v", len(usage.Rows), usage.Rows)
	}
	if usage.Rows[0].Type != "Images" || usage.Rows[0].Reclaimable != "793.8MB" {
		t.Fatalf("unexpected Images row: %+v", usage.Rows[0])
	}
	if usage.Rows[0].SizeBytes <= 0 || usage.Rows[0].ReclaimableBytes <= 0 {
		t.Fatalf("expected parsed byte sizes for Images, got %+v", usage.Rows[0])
	}
	if usage.Rows[3].Type != "Build Cache" || usage.Rows[3].ReclaimableBytes <= 0 {
		t.Fatalf("unexpected Build Cache row: %+v", usage.Rows[3])
	}
}
