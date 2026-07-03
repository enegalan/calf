package migration

import "testing"

func TestParseHumanSize(t *testing.T) {
	tests := []struct {
		input string
		gib   float64
		mib   float64
	}{
		{"17.82GB", 17.82, 0},
		{"10.12GB", 10.12, 0},
		{"227.8MB", 0, 227.8},
		{"0B", 0, 0},
	}

	for _, test := range tests {
		got, err := parseHumanSize(test.input)
		if err != nil {
			t.Fatalf("parseHumanSize(%q) error: %v", test.input, err)
		}

		var want int64
		if test.gib > 0 {
			want = int64(test.gib * 1024 * 1024 * 1024)
		} else if test.mib > 0 {
			want = int64(test.mib * 1024 * 1024)
		}

		diff := got - want
		if diff < 0 {
			diff = -diff
		}
		if diff > 1024 {
			t.Fatalf("parseHumanSize(%q) = %d, want ~%d", test.input, got, want)
		}
	}
}

func TestParseAvailBytesIgnoresLimaWarnings(t *testing.T) {
	output := `time="2026-07-02T16:27:05+02:00" level=warning msg="Non-strict YAML detected"
Avail
107374182400`

	got, err := parseAvailBytes([]byte(output))
	if err != nil {
		t.Fatalf("parseAvailBytes() error: %v", err)
	}

	if got != 107374182400 {
		t.Fatalf("parseAvailBytes() = %d, want 107374182400", got)
	}
}
