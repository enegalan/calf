package buildhistory

import "testing"

func TestParseInspectDetail(t *testing.T) {
	detail, err := parseInspectDetail(`{"Context":"/Users/egalan/git/toth","Dockerfile":"apps/api/Dockerfile"}`)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if detail.Context != "/Users/egalan/git/toth" {
		t.Fatalf("unexpected context: %q", detail.Context)
	}
	if detail.Dockerfile != "apps/api/Dockerfile" {
		t.Fatalf("unexpected dockerfile: %q", detail.Dockerfile)
	}
}

func TestParseInspectDetailDefaultsDockerfile(t *testing.T) {
	detail, err := parseInspectDetail(`{"Context":"/tmp/build"}`)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if detail.Dockerfile != "Dockerfile" {
		t.Fatalf("unexpected dockerfile: %q", detail.Dockerfile)
	}
}

func TestParseInspectDetailPreservesContextWithSpaces(t *testing.T) {
	detail, err := parseInspectDetail(`{"Context":"/Users/egalan/git/my project","Dockerfile":"Dockerfile"}`)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if detail.Context != "/Users/egalan/git/my project" {
		t.Fatalf("unexpected context: %q", detail.Context)
	}
}
