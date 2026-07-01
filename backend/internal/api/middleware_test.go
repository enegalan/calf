package api

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestLoggingMiddlewareRecordsStatus(t *testing.T) {
	logger := slog.Default()
	handler := loggingMiddleware(logger, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))

	req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected status 404, got %d", rec.Code)
	}
}

func TestRecoveryMiddleware(t *testing.T) {
	logger := slog.Default()
	handler := recoveryMiddleware(logger, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("test panic")
	}))

	req := httptest.NewRequest(http.MethodGet, "/v1/health", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected status 500, got %d", rec.Code)
	}

	if rec.Body.String() != "{\"error\":\"internal server error\"}\n" {
		t.Fatalf("unexpected body: %s", rec.Body.String())
	}
}
