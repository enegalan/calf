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
