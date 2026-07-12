package utils_test

import (
	"testing"

	"github.com/enegalan/calf/backend/internal/utils"
)

func TestParseDockerHumanSize(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    int64
		wantErr bool
	}{
		{
			name:  "empty",
			input: "",
			want:  0,
		},
		{
			name:  "zero B",
			input: "0B",
			want:  0,
		},
		{
			name:  "images from docker system df",
			input: "1.402GB",
			want:  1_402_000_000,
		},
		{
			name:  "containers from docker system df",
			input: "98.3kB",
			want:  98_300,
		},
		{
			name:  "local volumes from docker system df",
			input: "487.4kB",
			want:  487_400,
		},
		{
			name:  "build cache from docker system df",
			input: "793.8MB",
			want:  793_800_000,
		},
		{
			name:  "whole megabytes",
			input: "512MB",
			want:  512_000_000,
		},
		{
			name:    "unknown suffix",
			input:   "1.2TB",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := utils.ParseDockerHumanSize(tt.input)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("ParseDockerHumanSize(%q) expected error", tt.input)
				}
				return
			}
			if err != nil {
				t.Fatalf("ParseDockerHumanSize(%q) error: %v", tt.input, err)
			}
			if got != tt.want {
				t.Fatalf("ParseDockerHumanSize(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}
