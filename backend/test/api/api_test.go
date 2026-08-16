package api_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/enegalan/calf/backend/internal/api"
	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/middleware"
	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/gorilla/websocket"
)

func newTestGateway(cfg config.Config, logger *slog.Logger, mock *runtime.Mock) *api.Gateway {
	return api.New(cfg, logger, mock).WithMiddleware(
		middleware.CORS(),
		middleware.Recovery(logger),
		middleware.Logging(logger),
	)
}

func newTestServer(t *testing.T) *httptest.Server {
	return newTestServerWithMock(t, runtime.NewMock())
}

func newTestServerWithMock(t *testing.T, mock *runtime.Mock) *httptest.Server {
	t.Helper()

	dir := t.TempDir()
	t.Setenv("HOME", dir)

	cfg := config.Config{
		ListenAddr: ":8765",
		LogLevel:   "info",
	}

	apiServer := newTestGateway(cfg, slog.Default(), mock)
	server := httptest.NewServer(apiServer.Handler())
	t.Cleanup(func() {
		apiServer.Shutdown(context.Background())
		server.Close()
	})
	return server
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

	for _, key := range []string{"version", "uptime_seconds", "listen_addr", "log_level", "runtime", "resources"} {
		if _, ok := payload[key]; !ok {
			t.Fatalf("expected %q in response", key)
		}
	}

	resources, ok := payload["resources"].(map[string]any)
	if !ok {
		t.Fatalf("expected resources object, got %T", payload["resources"])
	}
	for _, key := range []string{"cpu_percent", "memory_used_bytes", "memory_reserved_bytes", "disk_used_bytes", "disk_reserved_bytes"} {
		if _, ok := resources[key]; !ok {
			t.Fatalf("expected resources.%q in response", key)
		}
	}
}

func TestStatusReportsStartingWhileStartInFlight(t *testing.T) {
	mock := runtime.NewMock()
	mock.Started = false
	mock.StatusValue.State = "stopped"
	hold := make(chan struct{})
	mock.StartHold = hold
	server := newTestServerWithMock(t, mock)
	defer server.Close()

	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(hold) }) }

	startDone := make(chan struct{})
	go func() {
		defer close(startDone)
		resp, err := http.Post(server.URL+"/v1/runtime/start", "application/json", nil)
		if err != nil {
			t.Errorf("POST /v1/runtime/start error: %v", err)
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Errorf("expected start status 200, got %d", resp.StatusCode)
		}
	}()
	defer func() {
		release()
		<-startDone
	}()

	deadline := time.Now().Add(2 * time.Second)
	var state string
	for time.Now().Before(deadline) {
		response, err := http.Get(server.URL + "/v1/status")
		if err != nil {
			t.Fatalf("GET /v1/status error: %v", err)
		}
		var payload map[string]any
		if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
			response.Body.Close()
			t.Fatalf("Decode() error: %v", err)
		}
		response.Body.Close()
		runtimePayload, ok := payload["runtime"].(map[string]any)
		if !ok {
			t.Fatalf("expected runtime object, got %T", payload["runtime"])
		}
		state, _ = runtimePayload["state"].(string)
		if state == "starting" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if state != "starting" {
		t.Fatalf("expected runtime state starting while Start is in flight, got %q", state)
	}

	release()
	<-startDone

	response, err := http.Get(server.URL + "/v1/status")
	if err != nil {
		t.Fatalf("GET /v1/status after start error: %v", err)
	}
	defer response.Body.Close()
	var payload map[string]any
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}
	runtimePayload, ok := payload["runtime"].(map[string]any)
	if !ok {
		t.Fatalf("expected runtime object, got %T", payload["runtime"])
	}
	if got, _ := runtimePayload["state"].(string); got != "running" {
		t.Fatalf("expected runtime state running after Start, got %q", got)
	}
}

func TestRuntimeStopAndKill(t *testing.T) {
	mock := runtime.NewMock()
	server := newTestServerWithMock(t, mock)
	defer server.Close()

	stopResp, err := http.Post(server.URL+"/v1/runtime/stop", "application/json", nil)
	if err != nil {
		t.Fatalf("POST /v1/runtime/stop error: %v", err)
	}
	defer stopResp.Body.Close()
	if stopResp.StatusCode != http.StatusOK {
		t.Fatalf("expected stop status 200, got %d", stopResp.StatusCode)
	}
	if mock.Started {
		t.Fatal("expected mock runtime stopped after /stop")
	}

	startResp, err := http.Post(server.URL+"/v1/runtime/start", "application/json", nil)
	if err != nil {
		t.Fatalf("POST /v1/runtime/start error: %v", err)
	}
	defer startResp.Body.Close()
	if startResp.StatusCode != http.StatusOK {
		t.Fatalf("expected start status 200, got %d", startResp.StatusCode)
	}
	if !mock.Started {
		t.Fatal("expected mock runtime started after /start")
	}

	killResp, err := http.Post(server.URL+"/v1/runtime/kill", "application/json", nil)
	if err != nil {
		t.Fatalf("POST /v1/runtime/kill error: %v", err)
	}
	defer killResp.Body.Close()
	if killResp.StatusCode != http.StatusOK {
		t.Fatalf("expected kill status 200, got %d", killResp.StatusCode)
	}
	if mock.Started {
		t.Fatal("expected mock runtime stopped after /kill")
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

func TestContainersEmptyListIsJSONArray(t *testing.T) {
	mock := runtime.NewMock()
	mock.Containers = nil
	server := newTestServerWithMock(t, mock)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/containers")
	if err != nil {
		t.Fatalf("GET /v1/containers error: %v", err)
	}
	defer response.Body.Close()

	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("ReadAll() error: %v", err)
	}
	if string(body) != "[]\n" {
		t.Fatalf("expected empty JSON array, got %q", body)
	}
}

func TestResourceListsRemainDuringResourceSaver(t *testing.T) {
	mock := runtime.NewMock()
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	cfg := config.Config{
		ListenAddr: ":8765",
		LogLevel:   "info",
	}
	apiServer := newTestGateway(cfg, slog.Default(), mock)
	server := httptest.NewServer(apiServer.Handler())
	t.Cleanup(func() {
		apiServer.Shutdown(context.Background())
		server.Close()
	})

	assertListLen := func(path string, want int) {
		t.Helper()
		response, err := http.Get(server.URL + path)
		if err != nil {
			t.Fatalf("GET %s error: %v", path, err)
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			t.Fatalf("GET %s expected status 200, got %d", path, response.StatusCode)
		}
		var items []map[string]any
		if err := json.NewDecoder(response.Body).Decode(&items); err != nil {
			t.Fatalf("GET %s Decode() error: %v", path, err)
		}
		if len(items) != want {
			t.Fatalf("GET %s expected %d items, got %d", path, want, len(items))
		}
	}

	assertListLen("/v1/containers", 1)
	assertListLen("/v1/images", 1)
	assertListLen("/v1/volumes", 1)
	assertListLen("/v1/networks", 1)

	if err := apiServer.Backend().EnterResourceSaver(context.Background()); err != nil {
		t.Fatalf("EnterResourceSaver: %v", err)
	}

	statusResp, err := http.Get(server.URL + "/v1/status")
	if err != nil {
		t.Fatalf("GET /v1/status error: %v", err)
	}
	defer statusResp.Body.Close()
	var status map[string]any
	if err := json.NewDecoder(statusResp.Body).Decode(&status); err != nil {
		t.Fatalf("GET /v1/status Decode() error: %v", err)
	}
	if status["resource_saver_active"] != true {
		t.Fatalf("expected resource_saver_active true, got %#v", status["resource_saver_active"])
	}

	assertListLen("/v1/containers", 1)
	assertListLen("/v1/images", 1)
	assertListLen("/v1/volumes", 1)
	assertListLen("/v1/networks", 1)

	killResp, err := http.Post(server.URL+"/v1/runtime/kill", "application/json", nil)
	if err != nil {
		t.Fatalf("POST /v1/runtime/kill error: %v", err)
	}
	defer killResp.Body.Close()
	if killResp.StatusCode != http.StatusOK {
		t.Fatalf("expected kill status 200, got %d", killResp.StatusCode)
	}

	assertListLen("/v1/containers", 0)
	assertListLen("/v1/images", 0)
	assertListLen("/v1/volumes", 0)
	assertListLen("/v1/networks", 0)
}

func TestStartContainerWakesResourceSaver(t *testing.T) {
	mock := runtime.NewMock()
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	cfg := config.Config{
		ListenAddr: ":8765",
		LogLevel:   "info",
	}
	apiServer := newTestGateway(cfg, slog.Default(), mock)
	server := httptest.NewServer(apiServer.Handler())
	t.Cleanup(func() {
		apiServer.Shutdown(context.Background())
		server.Close()
	})

	if err := apiServer.Backend().EnterResourceSaver(context.Background()); err != nil {
		t.Fatalf("EnterResourceSaver: %v", err)
	}
	if mock.StatusValue.State == runtime.State("running") {
		t.Fatal("expected runtime stopped after Resource Saver")
	}

	response, err := http.Post(server.URL+"/v1/containers/abc123/start", "application/json", nil)
	if err != nil {
		t.Fatalf("POST /v1/containers/abc123/start error: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("expected start status 200, got %d body %s", response.StatusCode, body)
	}

	if apiServer.Backend().ResourceSaverActive() {
		t.Fatal("expected Resource Saver inactive after starting a container")
	}
	if mock.StatusValue.State != runtime.State("running") {
		t.Fatalf("expected runtime running after start, got %s", mock.StatusValue.State)
	}

	statusResp, err := http.Get(server.URL + "/v1/status")
	if err != nil {
		t.Fatalf("GET /v1/status error: %v", err)
	}
	defer statusResp.Body.Close()
	var status map[string]any
	if err := json.NewDecoder(statusResp.Body).Decode(&status); err != nil {
		t.Fatalf("GET /v1/status Decode() error: %v", err)
	}
	if status["resource_saver_active"] != false {
		t.Fatalf("expected resource_saver_active false, got %#v", status["resource_saver_active"])
	}

	listResp, err := http.Get(server.URL + "/v1/containers")
	if err != nil {
		t.Fatalf("GET /v1/containers error: %v", err)
	}
	defer listResp.Body.Close()
	var containers []map[string]any
	if err := json.NewDecoder(listResp.Body).Decode(&containers); err != nil {
		t.Fatalf("GET /v1/containers Decode() error: %v", err)
	}
	if len(containers) != 1 {
		t.Fatalf("expected 1 container after wake, got %d", len(containers))
	}
	if containers[0]["state"] != "running" {
		t.Fatalf("expected container running, got %#v", containers[0]["state"])
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

	var statsPayload map[string]any
	if err := json.NewDecoder(statsResponse.Body).Decode(&statsPayload); err != nil {
		t.Fatalf("Decode stats error: %v", err)
	}
	if _, ok := statsPayload["samples"]; !ok {
		t.Fatal("expected samples field in stats response")
	}
}

func TestContainerStatsHistoryClearedOnDelete(t *testing.T) {
	mock := runtime.NewMock()
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	cfg := config.Config{
		ListenAddr: ":8765",
		LogLevel:   "info",
	}
	gateway := newTestGateway(cfg, slog.Default(), mock)
	server := httptest.NewServer(gateway.Handler())
	t.Cleanup(func() {
		_ = gateway.Shutdown(context.Background())
		server.Close()
	})

	gateway.Backend().RecordContainerStats("abc123", runtime.ContainerStats{
		CPUPerc:  "3.00%",
		MemUsage: "1MB / 1GB",
		MemPerc:  "0.10%",
		NetIO:    "1B / 1B",
		BlockIO:  "1B / 1B",
		PIDs:     "2",
	}, time.Now())

	statsResponse, err := http.Get(server.URL + "/v1/containers/abc123/stats")
	if err != nil {
		t.Fatalf("GET stats error: %v", err)
	}
	defer statsResponse.Body.Close()

	var before map[string]any
	if err := json.NewDecoder(statsResponse.Body).Decode(&before); err != nil {
		t.Fatalf("Decode stats error: %v", err)
	}
	samples, ok := before["samples"].([]any)
	if !ok || len(samples) == 0 {
		t.Fatalf("expected retained samples before delete, got %#v", before["samples"])
	}

	deleteRequest, err := http.NewRequest(http.MethodDelete, server.URL+"/v1/containers/abc123", nil)
	if err != nil {
		t.Fatalf("NewRequest DELETE error: %v", err)
	}
	deleteResponse, err := http.DefaultClient.Do(deleteRequest)
	if err != nil {
		t.Fatalf("DELETE container error: %v", err)
	}
	defer deleteResponse.Body.Close()
	if deleteResponse.StatusCode != http.StatusOK {
		t.Fatalf("expected delete status 200, got %d", deleteResponse.StatusCode)
	}

	if len(gateway.Backend().ContainerStatsSamples("abc123")) != 0 {
		t.Fatal("expected stats history cleared after container delete")
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

func TestRegistryLoginStartAcceptsPost(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Post(server.URL+"/v1/registry/login", "application/json", nil)
	if err != nil {
		t.Fatalf("POST /v1/registry/login error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode == http.StatusMethodNotAllowed {
		t.Fatalf("POST /v1/registry/login returned 405 method not allowed")
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

func TestNetworksReturnsList(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/networks")
	if err != nil {
		t.Fatalf("GET /v1/networks error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	var networks []map[string]any
	if err := json.NewDecoder(response.Body).Decode(&networks); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if len(networks) != 1 {
		t.Fatalf("expected 1 network, got %d", len(networks))
	}
}

func TestNetworkDetailReturnsMetadata(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/networks/bridge")
	if err != nil {
		t.Fatalf("GET /v1/networks/bridge error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	var payload map[string]any
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	for _, key := range []string{"name", "driver", "scope", "subnet", "gateway", "created"} {
		if _, ok := payload[key]; !ok {
			t.Fatalf("expected %q in response", key)
		}
	}
}

func TestVolumeDetailReturnsMetadata(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/volumes/calf-data")
	if err != nil {
		t.Fatalf("GET /v1/volumes/calf-data error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	var payload map[string]any
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	for _, key := range []string{"name", "driver", "created", "in_use"} {
		if _, ok := payload[key]; !ok {
			t.Fatalf("expected %q in response", key)
		}
	}
}

func TestVolumeFilesReturnsList(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/volumes/calf-data/files")
	if err != nil {
		t.Fatalf("GET /v1/volumes/calf-data/files error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	var files []map[string]any
	if err := json.NewDecoder(response.Body).Decode(&files); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if len(files) != 2 {
		t.Fatalf("expected 2 files, got %d", len(files))
	}
}

func TestVolumeContainersReturnsList(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/volumes/calf-data/containers")
	if err != nil {
		t.Fatalf("GET /v1/volumes/calf-data/containers error: %v", err)
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

func TestVolumeExportsListAndCreate(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/volumes/calf-data/exports")
	if err != nil {
		t.Fatalf("GET /v1/volumes/calf-data/exports error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	createResponse, err := http.Post(
		server.URL+"/v1/volumes/calf-data/exports",
		"application/json",
		strings.NewReader(`{"type":"local_file","file_name":"calf-data.tar.gz","folder":"/tmp/exports"}`),
	)
	if err != nil {
		t.Fatalf("POST /v1/volumes/calf-data/exports error: %v", err)
	}
	defer createResponse.Body.Close()

	if createResponse.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(createResponse.Body)
		t.Fatalf("expected status 200, got %d: %s", createResponse.StatusCode, body)
	}

	var created map[string]any
	if err := json.NewDecoder(createResponse.Body).Decode(&created); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if created["status"] != "completed" {
		t.Fatalf("expected completed status, got %v", created["status"])
	}

	if created["downloadable"] != true {
		t.Fatalf("expected downloadable export")
	}
}

func TestVolumeExportSchedulesCRUD(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	listResponse, err := http.Get(server.URL + "/v1/volumes/calf-data/export-schedules")
	if err != nil {
		t.Fatalf("GET export-schedules error: %v", err)
	}
	defer listResponse.Body.Close()

	if listResponse.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", listResponse.StatusCode)
	}

	createResponse, err := http.Post(
		server.URL+"/v1/volumes/calf-data/export-schedules",
		"application/json",
		strings.NewReader(`{
			"enabled": true,
			"day_times": [
				{"day": 1, "times": ["03:00", "15:00"]},
				{"day": 2, "times": ["09:00"]}
			],
			"type": "local_file",
			"file_name": "{volume}-{timestamp}.tar.gz",
			"folder": "/tmp/exports"
		}`),
	)
	if err != nil {
		t.Fatalf("POST export-schedules error: %v", err)
	}
	defer createResponse.Body.Close()

	if createResponse.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(createResponse.Body)
		t.Fatalf("expected status 200, got %d: %s", createResponse.StatusCode, body)
	}

	var created map[string]any
	if err := json.NewDecoder(createResponse.Body).Decode(&created); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	scheduleID, ok := created["id"].(string)
	if !ok || scheduleID == "" {
		t.Fatalf("expected schedule id in response")
	}

	if created["next_run_at"] == nil || created["next_run_at"] == "" {
		t.Fatalf("expected next_run_at in response")
	}

	updateTimesRequest, err := http.NewRequest(
		http.MethodPut,
		server.URL+"/v1/volumes/calf-data/export-schedules/"+scheduleID,
		strings.NewReader(`{
			"enabled": true,
			"day_times": [
				{"day": 1, "times": ["05:30", "16:00"]},
				{"day": 2, "times": ["10:15"]}
			],
			"type": "local_file",
			"file_name": "{volume}-{timestamp}.tar.gz",
			"folder": "/tmp/exports"
		}`),
	)
	if err != nil {
		t.Fatalf("NewRequest() error: %v", err)
	}
	updateTimesRequest.Header.Set("Content-Type", "application/json")

	updateTimesResponse, err := http.DefaultClient.Do(updateTimesRequest)
	if err != nil {
		t.Fatalf("PUT export-schedules day_times error: %v", err)
	}
	defer updateTimesResponse.Body.Close()

	if updateTimesResponse.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(updateTimesResponse.Body)
		t.Fatalf("expected status 200, got %d: %s", updateTimesResponse.StatusCode, body)
	}

	var updated map[string]any
	if err := json.NewDecoder(updateTimesResponse.Body).Decode(&updated); err != nil {
		t.Fatalf("Decode() updated schedule error: %v", err)
	}

	dayTimes, ok := updated["day_times"].([]any)
	if !ok || len(dayTimes) != 2 {
		t.Fatalf("expected 2 day_times entries, got %#v", updated["day_times"])
	}

	monday, ok := dayTimes[0].(map[string]any)
	if !ok {
		t.Fatalf("expected day_times entry object, got %#v", dayTimes[0])
	}

	mondayTimes, ok := monday["times"].([]any)
	if !ok || len(mondayTimes) != 2 || mondayTimes[0] != "05:30" {
		t.Fatalf("expected Monday times [05:30, 16:00], got %#v", monday["times"])
	}

	listAfterUpdate, err := http.Get(server.URL + "/v1/volumes/calf-data/export-schedules")
	if err != nil {
		t.Fatalf("GET export-schedules after update error: %v", err)
	}
	defer listAfterUpdate.Body.Close()

	var schedules []map[string]any
	if err := json.NewDecoder(listAfterUpdate.Body).Decode(&schedules); err != nil {
		t.Fatalf("Decode() schedules error: %v", err)
	}

	if len(schedules) != 1 {
		t.Fatalf("expected 1 schedule, got %d", len(schedules))
	}

	storedDayTimes, ok := schedules[0]["day_times"].([]any)
	if !ok || len(storedDayTimes) != 2 {
		t.Fatalf("expected stored day_times to persist, got %#v", schedules[0]["day_times"])
	}

	updateRequest, err := http.NewRequest(
		http.MethodPut,
		server.URL+"/v1/volumes/calf-data/export-schedules/"+scheduleID,
		strings.NewReader(`{"enabled": false}`),
	)
	if err != nil {
		t.Fatalf("NewRequest() error: %v", err)
	}
	updateRequest.Header.Set("Content-Type", "application/json")

	updateResponse, err := http.DefaultClient.Do(updateRequest)
	if err != nil {
		t.Fatalf("PUT export-schedules error: %v", err)
	}
	defer updateResponse.Body.Close()

	if updateResponse.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(updateResponse.Body)
		t.Fatalf("expected status 200, got %d: %s", updateResponse.StatusCode, body)
	}

	deleteRequest, err := http.NewRequest(
		http.MethodDelete,
		server.URL+"/v1/volumes/calf-data/export-schedules/"+scheduleID,
		nil,
	)
	if err != nil {
		t.Fatalf("NewRequest() error: %v", err)
	}

	deleteResponse, err := http.DefaultClient.Do(deleteRequest)
	if err != nil {
		t.Fatalf("DELETE export-schedules error: %v", err)
	}
	defer deleteResponse.Body.Close()

	if deleteResponse.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", deleteResponse.StatusCode)
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
	request.Header.Set("Origin", "http://localhost:54321")

	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("Do() error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("expected status 204, got %d", response.StatusCode)
	}

	if origin := response.Header.Get("Access-Control-Allow-Origin"); origin != "http://localhost:54321" {
		t.Fatalf("expected CORS origin reflected for localhost, got %q", origin)
	}
}

func TestHealthOptionsOmitsCORSHeaderForRemoteOrigin(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	request, err := http.NewRequest(http.MethodOptions, server.URL+"/v1/health", nil)
	if err != nil {
		t.Fatalf("NewRequest() error: %v", err)
	}
	request.Header.Set("Origin", "http://example.com")

	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("Do() error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("expected status 204, got %d", response.StatusCode)
	}

	if origin := response.Header.Get("Access-Control-Allow-Origin"); origin != "" {
		t.Fatalf("expected no CORS origin for remote origin, got %q", origin)
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

func TestContainerLogsWebSocketStreamsLines(t *testing.T) {
	mock := runtime.NewMock()
	mock.LogLines = []string{"alpha", "beta", "gamma"}
	server := newTestServerWithMock(t, mock)

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/containers/mock-id/logs"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("Dial() error: %v", err)
	}
	defer conn.Close()

	conn.SetReadDeadline(time.Now().Add(5 * time.Second))

	lines := make([]string, 0, 3)
	for range 3 {
		_, message, err := conn.ReadMessage()
		if err != nil {
			t.Fatalf("ReadMessage() error: %v", err)
		}
		lines = append(lines, string(message))
	}

	if strings.Join(lines, ",") != "alpha,beta,gamma" {
		t.Fatalf("unexpected lines: %v", lines)
	}
}

func TestPrunePreviewAndPrune(t *testing.T) {
	mock := runtime.NewMock()
	mock.Containers = append(mock.Containers, runtime.Container{
		ID:    "dead01",
		Name:  "old",
		Image: "alpine",
		State: "exited",
	})
	mock.Images = append(mock.Images, runtime.Image{
		ID:         "img999",
		Repository: "alpine",
		Tag:        "3.20",
		Size:       "5MB",
	})
	mock.Networks = append(mock.Networks, runtime.Network{
		ID:   "net123",
		Name: "app_net",
	})
	mock.SetBuildCacheBytes(1_000_000)
	server := newTestServerWithMock(t, mock)

	previewResponse, err := http.Get(server.URL + "/v1/system/prune/preview")
	if err != nil {
		t.Fatalf("GET preview error: %v", err)
	}
	defer previewResponse.Body.Close()
	if previewResponse.StatusCode != http.StatusOK {
		t.Fatalf("expected preview 200, got %d", previewResponse.StatusCode)
	}

	var preview runtime.PrunePreview
	if err := json.NewDecoder(previewResponse.Body).Decode(&preview); err != nil {
		t.Fatalf("Decode preview error: %v", err)
	}
	if len(preview.Containers.Items) != 1 {
		t.Fatalf("expected 1 stopped container, got %d", len(preview.Containers.Items))
	}

	pruneResponse, err := http.Post(
		server.URL+"/v1/system/prune",
		"application/json",
		strings.NewReader(`{"containers":true,"images":true,"networks":true,"build_cache":true}`),
	)
	if err != nil {
		t.Fatalf("POST prune error: %v", err)
	}
	defer pruneResponse.Body.Close()
	if pruneResponse.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(pruneResponse.Body)
		t.Fatalf("expected prune 200, got %d: %s", pruneResponse.StatusCode, body)
	}

	emptyResponse, err := http.Post(
		server.URL+"/v1/system/prune",
		"application/json",
		strings.NewReader(`{}`),
	)
	if err != nil {
		t.Fatalf("POST empty prune error: %v", err)
	}
	defer emptyResponse.Body.Close()
	if emptyResponse.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected empty prune 400, got %d", emptyResponse.StatusCode)
	}
}

func TestDebugLogsReturnsEmptyWhenMissing(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/debug/logs")
	if err != nil {
		t.Fatalf("GET /v1/debug/logs error: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", response.StatusCode)
	}

	var payload map[string]any
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}
	text, ok := payload["text"].(string)
	if !ok {
		t.Fatalf("expected string text, got %T", payload["text"])
	}
	if text != "" {
		t.Fatalf("expected empty text, got %q", text)
	}
	path, ok := payload["path"].(string)
	if !ok || path == "" {
		t.Fatalf("expected non-empty path, got %#v", payload["path"])
	}
}

func TestConfigPutLogLevel(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	putResp, err := putJSON(server.URL+"/v1/config", `{"log_level":"debug"}`)
	if err != nil {
		t.Fatalf("PUT /v1/config error: %v", err)
	}
	defer putResp.Body.Close()
	if putResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(putResp.Body)
		t.Fatalf("expected PUT 200, got %d: %s", putResp.StatusCode, body)
	}

	var cfg map[string]any
	if err := json.NewDecoder(putResp.Body).Decode(&cfg); err != nil {
		t.Fatalf("Decode config error: %v", err)
	}
	if cfg["log_level"] != "debug" {
		t.Fatalf("expected log_level debug, got %#v", cfg["log_level"])
	}

	statusResp, err := http.Get(server.URL + "/v1/status")
	if err != nil {
		t.Fatalf("GET /v1/status error: %v", err)
	}
	defer statusResp.Body.Close()
	var status map[string]any
	if err := json.NewDecoder(statusResp.Body).Decode(&status); err != nil {
		t.Fatalf("Decode status error: %v", err)
	}
	if status["log_level"] != "debug" {
		t.Fatalf("expected status log_level debug, got %#v", status["log_level"])
	}
}

func TestConfigPutLogLevelDoesNotApplyProxy(t *testing.T) {
	mock := runtime.NewMock()
	server := newTestServerWithMock(t, mock)
	defer server.Close()

	putResp, err := putJSON(server.URL+"/v1/config", `{"log_level":"debug","http_proxy":"","https_proxy":"","no_proxy":""}`)
	if err != nil {
		t.Fatalf("PUT /v1/config error: %v", err)
	}
	defer putResp.Body.Close()
	if putResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(putResp.Body)
		t.Fatalf("expected PUT 200, got %d: %s", putResp.StatusCode, body)
	}
	time.Sleep(100 * time.Millisecond)
	if got := mock.ApplyProxyCalls(); got != 0 {
		t.Fatalf("log_level update applied proxy %d times", got)
	}
}

func TestConfigPutProxyChangeAppliesProxy(t *testing.T) {
	mock := runtime.NewMock()
	server := newTestServerWithMock(t, mock)
	defer server.Close()

	putResp, err := putJSON(server.URL+"/v1/config", `{"http_proxy":"http://127.0.0.1:8080"}`)
	if err != nil {
		t.Fatalf("PUT /v1/config error: %v", err)
	}
	defer putResp.Body.Close()
	if putResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(putResp.Body)
		t.Fatalf("expected PUT 200, got %d: %s", putResp.StatusCode, body)
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if mock.ApplyProxyCalls() == 1 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("expected ApplyProxy once, got %d", mock.ApplyProxyCalls())
}

func TestConfigPutLogLevelInvalid(t *testing.T) {
	server := newTestServer(t)
	defer server.Close()

	putResp, err := putJSON(server.URL+"/v1/config", `{"log_level":"trace"}`)
	if err != nil {
		t.Fatalf("PUT /v1/config error: %v", err)
	}
	defer putResp.Body.Close()
	if putResp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected PUT 400, got %d", putResp.StatusCode)
	}
}

// putJSON sends a PUT request with a JSON body.
func putJSON(url, body string) (*http.Response, error) {
	req, err := http.NewRequest(http.MethodPut, url, strings.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	return http.DefaultClient.Do(req)
}
