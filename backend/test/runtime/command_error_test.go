package runtime_test

import (
	"fmt"
	"strings"
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
		{`error during connect: Get "http://%2FUsers%2Fegalan%2F.config%2Fcalf%2Fdocker.sock/_ping": EOF`, true},
		{`Get "http://%2FUsers%2Fegalan%2F.config%2Fcalf%2Fdocker.sock/_ping": EOF`, true},
		{"EOF: driver not connecting", true},
		{"EOF", true},
		{"exit status 1", false},
		{"image not found", false},
	}

	for _, testCase := range cases {
		err := fmt.Errorf("%s", testCase.message)
		if got := runtime.IsTransientCommandError(err); got != testCase.expected {
			t.Fatalf("isTransient(%q) = %v, want %v", testCase.message, got, testCase.expected)
		}
	}
}

func TestFormatCommandErrorPrefersUnknownCommand(t *testing.T) {
	output := "docker: unknown command: docker buildx\n\nRun 'docker --help' for more information\n"
	got := runtime.FormatCommandError(output)
	if got != "docker: unknown command: docker buildx" {
		t.Fatalf("FormatCommandError() = %q, want unknown-command line", got)
	}
}

func TestFormatCommandErrorPrefersConnectErrorAfterContainerLogs(t *testing.T) {
	cases := []struct {
		name   string
		output string
		want   string
	}{
		{
			name:   "connect without ERROR prefix",
			output: "app started\nerror: ignored earlier log\nerror during connect: Get \"http://sock/v1.55/containers/x/logs\": EOF\n",
			want:   "error during connect: Get \"http://sock/v1.55/containers/x/logs\": EOF",
		},
		{
			name:   "docker ERROR prefix",
			output: "app started\nerror: ignored earlier log\nERROR: error during connect: Get \"http://sock/v1.55/version\": EOF: driver not connecting\n",
			want:   "ERROR: error during connect: Get \"http://sock/v1.55/version\": EOF: driver not connecting",
		},
	}

	for _, testCase := range cases {
		got := runtime.FormatCommandError(testCase.output)
		if got != testCase.want {
			t.Fatalf("%s: FormatCommandError() = %q, want %q", testCase.name, got, testCase.want)
		}
	}
}

func TestWrapGuestWaitErrorIgnoresBuildxGCPolicy(t *testing.T) {
	waitErr := fmt.Errorf("error during connect: Post \"http://sock/v1.52/containers/abc/wait\": write unix ->/sock: write: broken pipe")
	logs := []byte("Name:          default\nDriver:        docker\nGC Policy rule#0:\n  Max Used Space: 9.313GiB\n  Min Free Space: 7.451GiB\n")
	got := runtime.WrapGuestWaitError(waitErr, logs)
	if got == nil {
		t.Fatal("WrapGuestWaitError() = nil")
	}
	if strings.Contains(got.Error(), "Min Free Space") {
		t.Fatalf("WrapGuestWaitError() = %q, must not treat GC policy as the failure", got)
	}
	if !strings.Contains(got.Error(), "broken pipe") {
		t.Fatalf("WrapGuestWaitError() = %q, want original wait error", got)
	}
}

func TestWrapGuestWaitErrorKeepsConnectMarker(t *testing.T) {
	waitErr := fmt.Errorf("write: broken pipe")
	logs := []byte("app started\nerror during connect: Get \"http://sock/_ping\": EOF\n")
	got := runtime.WrapGuestWaitError(waitErr, logs)
	if got == nil || !strings.Contains(got.Error(), "error during connect") {
		t.Fatalf("WrapGuestWaitError() = %v, want connect error from logs", got)
	}
}

func TestParseInspectStateLine(t *testing.T) {
	status, code, ok := runtime.ParseInspectStateLine("exited 0\n")
	if !ok || status != "exited" || code != "0" {
		t.Fatalf("ParseInspectStateLine() = %q %q %v", status, code, ok)
	}
	if _, _, ok := runtime.ParseInspectStateLine("running"); ok {
		t.Fatal("ParseInspectStateLine(running) ok = true")
	}
	if !runtime.InspectStateExited("exited") || runtime.InspectStateExited("running") {
		t.Fatal("InspectStateExited() mismatch")
	}
}

func TestKeepLastListUsesCacheOnError(t *testing.T) {
	cached := []string{"web", "db"}
	got, err := runtime.KeepLastList(cached, nil, fmt.Errorf("error during connect"))
	if err != nil {
		t.Fatalf("KeepLastList() error: %v", err)
	}
	if len(got) != 2 || got[0] != "web" || got[1] != "db" {
		t.Fatalf("KeepLastList() = %#v, want cached names", got)
	}
}

func TestKeepLastListLiveOnSuccess(t *testing.T) {
	cached := []string{"old"}
	live := []string{"new"}
	got, err := runtime.KeepLastList(cached, live, nil)
	if err != nil {
		t.Fatalf("KeepLastList() error: %v", err)
	}
	if len(got) != 1 || got[0] != "new" {
		t.Fatalf("KeepLastList() = %#v, want live list", got)
	}
}

func TestKeepLastListErrorWithoutCache(t *testing.T) {
	wantErr := fmt.Errorf("error during connect")
	got, err := runtime.KeepLastList([]string(nil), nil, wantErr)
	if err != wantErr {
		t.Fatalf("KeepLastList() err = %v, want original error", err)
	}
	if got != nil {
		t.Fatalf("KeepLastList() = %#v, want nil list", got)
	}
}
