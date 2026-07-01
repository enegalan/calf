package api_test

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/enegalan/calf/backend/internal/api"
	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/runtime"
)

func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()

	cfg := config.Config{
		ListenAddr: ":8080",
		LogLevel:   "info",
	}

	return httptest.NewServer(api.New(cfg, slog.Default(), runtime.NewMock()).Handler())
}

func TestHealthReturnsOk(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/health")
	if err != nil {
		t.Fatalf("GET /v1/health error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("ReadAll() error: %v", err)
	}

	if string(body) != "{\"status\":\"ok\"}\n" {
		t.Fatalf("unexpected body: %s", body)
	}
}

func TestStatusReturnsMetadata(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/status")
	if err != nil {
		t.Fatalf("GET /v1/status error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	var payload map[string]any
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	for _, key := range []string{"version", "uptime_seconds", "listen_addr", "log_level", "runtime"} {
		if _, ok := payload[key]; !ok {
			t.Fatalf("expected %q in response", key)
		}
	}
}

func TestContainersReturnsList(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/containers")
	if err != nil {
		t.Fatalf("GET /v1/containers error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	var containers []map[string]any
	if err := json.NewDecoder(response.Body).Decode(&containers); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if len(containers) != 1 {
		t.Fatalf("expected 1 container, got %d", len(containers))
	}
}

func TestImagesReturnsList(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/images")
	if err != nil {
		t.Fatalf("GET /v1/images error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	var images []map[string]any
	if err := json.NewDecoder(response.Body).Decode(&images); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if len(images) != 1 {
		t.Fatalf("expected 1 image, got %d", len(images))
	}
}

func TestHealthOptionsReturnsNoContent(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	request, err := http.NewRequest(http.MethodOptions, server.URL+"/v1/health", nil)
	if err != nil {
		t.Fatalf("NewRequest() error: %v", err)
	}

	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("Do() error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("expected status 204, got %d", response.StatusCode)
	}

	if origin := response.Header.Get("Access-Control-Allow-Origin"); origin != "*" {
		t.Fatalf("expected CORS origin *, got %q", origin)
	}
}

func TestHealthMethodNotAllowedReturnsJSONError(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	request, err := http.NewRequest(http.MethodPost, server.URL+"/v1/health", nil)
	if err != nil {
		t.Fatalf("NewRequest() error: %v", err)
	}

	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("Do() error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("expected status 405, got %d", response.StatusCode)
	}

	var payload map[string]string
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if payload["error"] != "method not allowed" {
		t.Fatalf("unexpected error message: %q", payload["error"])
	}
}
