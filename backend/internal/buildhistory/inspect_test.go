package buildhistory

import "testing"

func TestParseInspectDetail(t *testing.T) {
	detail := parseInspectDetail(`{"Context":"/Users/egalan/git/toth","Dockerfile":"apps/api/Dockerfile"}`)
	if detail.Context != "/Users/egalan/git/toth" {
		t.Fatalf("unexpected context: %q", detail.Context)
	}
	if detail.Dockerfile != "apps/api/Dockerfile" {
		t.Fatalf("unexpected dockerfile: %q", detail.Dockerfile)
	}
}

func TestParseInspectDetailDefaultsDockerfile(t *testing.T) {
	detail := parseInspectDetail(`{"Context":"/tmp/build"}`)
	if detail.Dockerfile != "Dockerfile" {
		t.Fatalf("unexpected dockerfile: %q", detail.Dockerfile)
	}
}

func TestParseInspectDetailPreservesContextWithSpaces(t *testing.T) {
	detail := parseInspectDetail(`{"Context":"/Users/egalan/git/my project","Dockerfile":"Dockerfile"}`)
	if detail.Context != "/Users/egalan/git/my project" {
		t.Fatalf("unexpected context: %q", detail.Context)
	}
}
