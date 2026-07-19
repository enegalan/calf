package runtime_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/klauspost/compress/zstd"
)

// TestDecompressZstdRoundTrip checks the pure-Go zstd path used for guest-disk seeds.
func TestDecompressZstdRoundTrip(t *testing.T) {
	dir := t.TempDir()
	rawPath := filepath.Join(dir, "disk.raw")
	zstPath := filepath.Join(dir, "disk.raw.zst")
	outPath := filepath.Join(dir, "out.raw")

	payload := []byte("calf-vfkit-guest-seed-test-payload")
	if err := os.WriteFile(rawPath, payload, 0o644); err != nil {
		t.Fatalf("write raw: %v", err)
	}

	raw, err := os.Open(rawPath)
	if err != nil {
		t.Fatalf("open raw: %v", err)
	}
	zstFile, err := os.Create(zstPath)
	if err != nil {
		_ = raw.Close()
		t.Fatalf("create zst: %v", err)
	}
	enc, err := zstd.NewWriter(zstFile)
	if err != nil {
		_ = raw.Close()
		_ = zstFile.Close()
		t.Fatalf("zstd writer: %v", err)
	}
	if _, err := enc.ReadFrom(raw); err != nil {
		_ = enc.Close()
		_ = raw.Close()
		_ = zstFile.Close()
		t.Fatalf("compress: %v", err)
	}
	_ = enc.Close()
	_ = raw.Close()
	_ = zstFile.Close()

	in, err := os.Open(zstPath)
	if err != nil {
		t.Fatalf("open zst: %v", err)
	}
	defer in.Close()
	dec, err := zstd.NewReader(in)
	if err != nil {
		t.Fatalf("zstd reader: %v", err)
	}
	defer dec.Close()
	out, err := os.Create(outPath)
	if err != nil {
		t.Fatalf("create out: %v", err)
	}
	if _, err := dec.WriteTo(out); err != nil {
		_ = out.Close()
		t.Fatalf("decompress: %v", err)
	}
	_ = out.Close()

	got, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("read out: %v", err)
	}
	if string(got) != string(payload) {
		t.Fatalf("payload mismatch: got %q want %q", got, payload)
	}
}
