package api

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/enegalan/calf/backend/internal/config"
)

func TestHandleHealth(t *testing.T) {
	server := New(testConfig(), slog.Default())

	req := httptest.NewRequest(http.MethodGet, "/v1/health", nil)
	rec := httptest.NewRecorder()
	server.handleHealth(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	if rec.Body.String() != "{\"status\":\"ok\"}\n" {
		t.Fatalf("unexpected body: %s", rec.Body.String())
	}
}

func TestHandleStatus(t *testing.T) {
	server := New(testConfig(), slog.Default())

	req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	rec := httptest.NewRecorder()
	server.handleStatus(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	if rec.Body.Len() == 0 {
		t.Fatal("expected non-empty body")
	}
}

func testConfig() config.Config {
	return config.Config{
		ListenAddr: ":8080",
		LogLevel:   "info",
	}
}
