package api_test

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
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

func TestContainerInspectAndMounts(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	inspectResponse, err := http.Get(server.URL + "/v1/containers/abc123/inspect")
	if err != nil {
		t.Fatalf("GET inspect error: %v", err)
	}
	defer inspectResponse.Body.Close()

	if inspectResponse.StatusCode != http.StatusOK {
		t.Fatalf("expected inspect status 200, got %d", inspectResponse.StatusCode)
	}

	mountsResponse, err := http.Get(server.URL + "/v1/containers/abc123/mounts")
	if err != nil {
		t.Fatalf("GET mounts error: %v", err)
	}
	defer mountsResponse.Body.Close()

	if mountsResponse.StatusCode != http.StatusOK {
		t.Fatalf("expected mounts status 200, got %d", mountsResponse.StatusCode)
	}

	statsResponse, err := http.Get(server.URL + "/v1/containers/abc123/stats")
	if err != nil {
		t.Fatalf("GET stats error: %v", err)
	}
	defer statsResponse.Body.Close()

	if statsResponse.StatusCode != http.StatusOK {
		t.Fatalf("expected stats status 200, got %d", statsResponse.StatusCode)
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

func TestImageLayersReturnsHistory(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/images/layers?reference=hello-world:latest")
	if err != nil {
		t.Fatalf("GET /v1/images/layers error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	var layers []map[string]any
	if err := json.NewDecoder(response.Body).Decode(&layers); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if len(layers) != 3 {
		t.Fatalf("expected 3 layers, got %d", len(layers))
	}
}

func TestImageRunReturnsContainerID(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Post(server.URL+"/v1/images/run", "application/json", strings.NewReader(`{"reference":"hello-world:latest"}`))
	if err != nil {
		t.Fatalf("POST /v1/images/run error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	var payload map[string]string
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if payload["container_id"] == "" {
		t.Fatalf("expected container_id in response")
	}
}

func TestImagePushReturnsOk(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Post(server.URL+"/v1/images/push", "application/json", strings.NewReader(`{"reference":"hello-world:latest"}`))
	if err != nil {
		t.Fatalf("POST /v1/images/push error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}
}

func TestRegistryStatusReturnsNotLoggedIn(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/registry")
	if err != nil {
		t.Fatalf("GET /v1/registry error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	var payload map[string]any
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if payload["logged_in"] != false {
		t.Fatalf("expected logged_in=false, got %v", payload["logged_in"])
	}
}

func TestRegistryLoginReturnsOk(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Post(
		server.URL+"/v1/registry",
		"application/json",
		strings.NewReader(`{"username":"demo","password":"secret"}`),
	)
	if err != nil {
		t.Fatalf("POST /v1/registry error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	statusResponse, err := http.Get(server.URL + "/v1/registry")
	if err != nil {
		t.Fatalf("GET /v1/registry error: %v", err)
	}
	defer statusResponse.Body.Close()

	var status map[string]any
	if err := json.NewDecoder(statusResponse.Body).Decode(&status); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if status["logged_in"] != true {
		t.Fatalf("expected logged_in=true after login, got %v", status["logged_in"])
	}
}

func TestRegistryLogoutReturnsOk(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	loginResponse, err := http.Post(
		server.URL+"/v1/registry",
		"application/json",
		strings.NewReader(`{"username":"demo","password":"secret"}`),
	)
	if err != nil {
		t.Fatalf("POST /v1/registry error: %v", err)
	}
	loginResponse.Body.Close()

	if loginResponse.StatusCode != http.StatusOK {
		t.Fatalf("expected login status 200, got %d", loginResponse.StatusCode)
	}

	logoutRequest, err := http.NewRequest(http.MethodDelete, server.URL+"/v1/registry", nil)
	if err != nil {
		t.Fatalf("NewRequest() error: %v", err)
	}

	logoutResponse, err := http.DefaultClient.Do(logoutRequest)
	if err != nil {
		t.Fatalf("DELETE /v1/registry error: %v", err)
	}
	defer logoutResponse.Body.Close()

	if logoutResponse.StatusCode != http.StatusOK {
		t.Fatalf("expected logout status 200, got %d", logoutResponse.StatusCode)
	}

	statusResponse, err := http.Get(server.URL + "/v1/registry")
	if err != nil {
		t.Fatalf("GET /v1/registry error: %v", err)
	}
	defer statusResponse.Body.Close()

	var status map[string]any
	if err := json.NewDecoder(statusResponse.Body).Decode(&status); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if status["logged_in"] != false {
		t.Fatalf("expected logged_in=false after logout, got %v", status["logged_in"])
	}
}

func TestRegistryLoginSessionNotFound(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/registry/login/missing")
	if err != nil {
		t.Fatalf("GET /v1/registry/login/missing error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("expected status 404, got %d", response.StatusCode)
	}
}

func TestVolumesReturnsList(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/volumes")
	if err != nil {
		t.Fatalf("GET /v1/volumes error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	var volumes []map[string]any
	if err := json.NewDecoder(response.Body).Decode(&volumes); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if len(volumes) != 1 {
		t.Fatalf("expected 1 volume, got %d", len(volumes))
	}
}

func TestBuildsReturnsEmptyList(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/builds")
	if err != nil {
		t.Fatalf("GET /v1/builds error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	var builds []map[string]any
	if err := json.NewDecoder(response.Body).Decode(&builds); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if len(builds) != 0 {
		t.Fatalf("expected 0 builds, got %d", len(builds))
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
