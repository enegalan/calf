package runtime

import "testing"

func TestDecodeInspectDocumentsSingleArray(t *testing.T) {
	output := []byte(`[{"Name":"a"},{"Name":"b"}]`)

	rows, err := decodeInspectDocuments[map[string]string](output)
	if err != nil {
		t.Fatalf("decodeInspectDocuments() error: %v", err)
	}

	if len(rows) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(rows))
	}
}

func TestDecodeInspectDocumentsConcatenatedArrays(t *testing.T) {
	output := []byte(`[{"Name":"a"}][{"Name":"b"}]`)

	rows, err := decodeInspectDocuments[map[string]string](output)
	if err != nil {
		t.Fatalf("decodeInspectDocuments() error: %v", err)
	}

	if len(rows) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(rows))
	}
}

func TestDecodeInspectDocumentsSkipsLogLines(t *testing.T) {
	output := []byte("time=2026-07-04T00:37:02 level=info msg=inspect\n[{\"Name\":\"a\"}]\ntime=2026-07-04T00:37:03 level=info msg=done\n[{\"Name\":\"b\"}]")

	rows, err := decodeInspectDocuments[map[string]string](output)
	if err != nil {
		t.Fatalf("decodeInspectDocuments() error: %v", err)
	}

	if len(rows) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(rows))
	}
}
