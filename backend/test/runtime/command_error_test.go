package runtime_test

import (
	"fmt"
	"strings"
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestFormatCommandErrorExtractsFatalMessage(t *testing.T) {
	output := "elapsed: 1.2 s total: 0.0 B\n" +
		`time="2026-07-03T00:31:21+02:00" level=fatal msg="push access denied, repository does not exist or may require authorization: server message: insufficient_scope: authorization failed"`

	message := runtime.FormatCommandError(output)
	if !strings.Contains(message, "push access denied") {
		t.Fatalf("unexpected message: %q", message)
	}

	if strings.Contains(message, "elapsed:") {
		t.Fatalf("progress output leaked into message: %q", message)
	}
}

func TestWrapPushErrorHintsForUnnamespacedImage(t *testing.T) {
	err := runtime.WrapPushError("toth-web:latest", fmt.Errorf("push access denied"))
	message := err.Error()

	if !strings.Contains(message, "docker.io/USERNAME/toth-web:latest") {
		t.Fatalf("expected tagging hint, got: %q", message)
	}
}

func TestWrapPushErrorHintsForNamespacedImage(t *testing.T) {
	err := runtime.WrapPushError("docker.io/user/toth-web:latest", fmt.Errorf("push access denied"))
	message := err.Error()

	if !strings.Contains(message, "Sign in to Docker Hub from Settings") {
		t.Fatalf("expected login hint, got: %q", message)
	}
}
