package runtime_test

import (
	"fmt"
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestIsTransientCommandError(t *testing.T) {
	cases := []struct {
		message  string
		expected bool
	}{
		{"sudo: unable to execute /usr/local/bin/nerdctl: Text file busy", true},
		{"connection refused", true},
		{"image not found", false},
	}

	for _, testCase := range cases {
		err := fmt.Errorf("%s", testCase.message)
		if got := runtime.IsTransientCommandError(err); got != testCase.expected {
			t.Fatalf("isTransient(%q) = %v, want %v", testCase.message, got, testCase.expected)
		}
	}
}
