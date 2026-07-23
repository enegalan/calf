package api_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
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
