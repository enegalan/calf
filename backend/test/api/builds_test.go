package api_test

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/enegalan/calf/backend/internal/buildstore"
	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestBuildsPersistAcrossServerReload(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	cfg := config.Config{ListenAddr: ":8765", LogLevel: "info"}
	mock := runtime.NewMock()

	server := httptest.NewServer(newTestGateway(cfg, slog.Default(), mock).Handler())
	response, err := http.Post(server.URL+"/v1/builds", "application/json", bytes.NewBufferString(`{
		"context": ".",
		"tag": "demo:test"
	}`))
	if err != nil {
		t.Fatalf("POST /v1/builds error: %v", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("expected status 202, got %d: %s", response.StatusCode, body)
	}

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		listResponse, err := http.Get(server.URL + "/v1/builds")
		if err != nil {
			t.Fatalf("GET /v1/builds error: %v", err)
		}

		var builds []map[string]any
		_ = json.NewDecoder(listResponse.Body).Decode(&builds)
		listResponse.Body.Close()

		if len(builds) == 1 && builds[0]["status"] == "success" {
			break
		}

		time.Sleep(100 * time.Millisecond)
	}

	server.Close()

	file, err := buildstore.Load()
	if err != nil {
		t.Fatalf("Load() error: %v", err)
	}
	if len(file.Builds) != 1 {
		t.Fatalf("expected 1 persisted build, got %d", len(file.Builds))
	}

	reloaded := httptest.NewServer(newTestGateway(cfg, slog.Default(), mock).Handler())
	defer reloaded.Close()

	listResponse, err := http.Get(reloaded.URL + "/v1/builds")
	if err != nil {
		t.Fatalf("GET /v1/builds after reload error: %v", err)
	}
	defer listResponse.Body.Close()

	var builds []map[string]any
	if err := json.NewDecoder(listResponse.Body).Decode(&builds); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if len(builds) != 1 {
		t.Fatalf("expected 1 build after reload, got %d", len(builds))
	}
}

func TestBuildDetailAndSourceEndpoints(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	contextDir := filepath.Join(dir, "context")
	if err := os.MkdirAll(contextDir, 0o755); err != nil {
		t.Fatalf("MkdirAll() error: %v", err)
	}

	dockerfile := "FROM alpine:latest\nRUN echo hello\n"
	if err := os.WriteFile(filepath.Join(contextDir, "Dockerfile"), []byte(dockerfile), 0o644); err != nil {
		t.Fatalf("WriteFile() error: %v", err)
	}

	cfg := config.Config{ListenAddr: ":8765", LogLevel: "info"}
	mock := runtime.NewMock()
	server := httptest.NewServer(newTestGateway(cfg, slog.Default(), mock).Handler())
	defer server.Close()

	response, err := http.Post(server.URL+"/v1/builds", "application/json", bytes.NewBufferString(`{
		"context": "`+contextDir+`",
		"tag": "demo:test"
	}`))
	if err != nil {
		t.Fatalf("POST /v1/builds error: %v", err)
	}
	response.Body.Close()

	var buildID string
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		listResponse, err := http.Get(server.URL + "/v1/builds")
		if err != nil {
			t.Fatalf("GET /v1/builds error: %v", err)
		}

		var builds []map[string]any
		_ = json.NewDecoder(listResponse.Body).Decode(&builds)
		listResponse.Body.Close()

		if len(builds) == 1 && builds[0]["status"] == "success" {
			buildID, _ = builds[0]["id"].(string)
			break
		}

		time.Sleep(100 * time.Millisecond)
	}

	if buildID == "" {
		t.Fatalf("expected completed build id")
	}

	detailResponse, err := http.Get(server.URL + "/v1/builds/" + buildID)
	if err != nil {
		t.Fatalf("GET /v1/builds/{id} error: %v", err)
	}
	defer detailResponse.Body.Close()

	if detailResponse.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(detailResponse.Body)
		t.Fatalf("expected status 200, got %d: %s", detailResponse.StatusCode, body)
	}

	var detail map[string]any
	if err := json.NewDecoder(detailResponse.Body).Decode(&detail); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if detail["id"] != buildID {
		t.Fatalf("expected build id %q, got %v", buildID, detail["id"])
	}

	sourceResponse, err := http.Get(server.URL + "/v1/builds/" + buildID + "/source")
	if err != nil {
		t.Fatalf("GET /v1/builds/{id}/source error: %v", err)
	}
	defer sourceResponse.Body.Close()

	if sourceResponse.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(sourceResponse.Body)
		t.Fatalf("expected status 200, got %d: %s", sourceResponse.StatusCode, body)
	}

	var source map[string]any
	if err := json.NewDecoder(sourceResponse.Body).Decode(&source); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if source["content"] != dockerfile {
		t.Fatalf("unexpected dockerfile content: %v", source["content"])
	}

	logsResponse, err := http.Get(server.URL + "/v1/builds/" + buildID + "/logs")
	if err != nil {
		t.Fatalf("GET /v1/builds/{id}/logs error: %v", err)
	}
	defer logsResponse.Body.Close()

	if logsResponse.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(logsResponse.Body)
		t.Fatalf("expected logs status 200, got %d: %s", logsResponse.StatusCode, body)
	}

	var logs map[string]any
	if err := json.NewDecoder(logsResponse.Body).Decode(&logs); err != nil {
		t.Fatalf("Decode() error: %v", err)
	}

	if logs["raw_log"] == "" {
		t.Fatalf("expected build logs content")
	}
}
