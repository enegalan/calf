package httpkit_test

import (
	"testing"

	"github.com/enegalan/calf/backend/internal/httpkit"
)

func TestIsLocalOrigin(t *testing.T) {
	cases := []struct {
		origin string
		want   bool
	}{
		{"", false},
		{"http://127.0.0.1:8765", true},
		{"http://localhost:3000", true},
		{"http://[::1]:8765", true},
		{"https://evil.example", false},
		{"not a url", false},
	}

	for _, tc := range cases {
		if got := httpkit.IsLocalOrigin(tc.origin); got != tc.want {
			t.Fatalf("IsLocalOrigin(%q) = %v, want %v", tc.origin, got, tc.want)
		}
	}
}

func TestIsLocalHost(t *testing.T) {
	cases := []struct {
		host string
		want bool
	}{
		{"localhost", true},
		{"127.0.0.1", true},
		{"::1", true},
		{"0.0.0.0", false},
		{"example.com", false},
	}

	for _, tc := range cases {
		if got := httpkit.IsLocalHost(tc.host); got != tc.want {
			t.Fatalf("IsLocalHost(%q) = %v, want %v", tc.host, got, tc.want)
		}
	}
}
