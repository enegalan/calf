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
