package runtime_test

import (
	"testing"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestRegistryStatusFromConfigDetectsDockerHubAuth(t *testing.T) {
	output := []byte(`{
		"auths": {
			"https://index.docker.io/v1/": {
				"auth": "ZW5lZ2FsYW46dGNrcl9wYXRf"
			}
		}
	}`)

	status := runtime.RegistryStatusFromConfig(output)
	if !status.LoggedIn {
		t.Fatalf("expected logged_in=true")
	}

	if status.Username != "enegalan" {
		t.Fatalf("expected username enegalan, got %q", status.Username)
	}
}

func TestRegistryStatusFromCredentialHelpersUsesCredsStore(t *testing.T) {
	output := []byte(`{
		"auths": {
			"https://index.docker.io/v1/": {}
		},
		"credsStore": "osxkeychain"
	}`)

	status := runtime.RegistryStatusFromCredentialHelpers(output, func(helper, serverURL string) (string, bool) {
		if helper != "osxkeychain" {
			t.Fatalf("helper = %q, want osxkeychain", helper)
		}
		if serverURL != "https://index.docker.io/v1/" {
			t.Fatalf("serverURL = %q, want https://index.docker.io/v1/", serverURL)
		}
		return "enegalan", true
	})

	if !status.LoggedIn {
		t.Fatalf("expected logged_in=true")
	}
	if status.Username != "enegalan" {
		t.Fatalf("expected username enegalan, got %q", status.Username)
	}
}

func TestParseCredentialHelperUsername(t *testing.T) {
	username, ok := runtime.ParseCredentialHelperUsername([]byte(
		`{"ServerURL":"https://index.docker.io/v1/","Username":"enegalan","Secret":"redacted"}`,
	))
	if !ok {
		t.Fatal("expected username")
	}
	if username != "enegalan" {
		t.Fatalf("username = %q, want enegalan", username)
	}
}
