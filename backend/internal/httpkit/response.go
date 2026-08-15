package httpkit

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"reflect"
	"strings"
)

// WriteJSON encodes payload as JSON and writes it with the given HTTP status.
// Nil slices encode as [] so list endpoints never return JSON null.
func WriteJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(nonNilJSONPayload(payload))
}

// nonNilJSONPayload replaces a nil slice with an empty slice of the same type.
func nonNilJSONPayload(payload any) any {
	if payload == nil {
		return payload
	}
	value := reflect.ValueOf(payload)
	if value.Kind() != reflect.Slice || !value.IsNil() {
		return payload
	}
	return reflect.MakeSlice(value.Type(), 0, 0).Interface()
}

// WriteError writes a JSON error response with the given status and message.
func WriteError(w http.ResponseWriter, status int, message string) {
	WriteJSON(w, status, map[string]string{"error": message})
}

// WriteLoggedError logs err alongside publicMsg, then writes publicMsg as the JSON error response
// so internal error details (paths, command output, wrapped errors) never reach the client.
func WriteLoggedError(logger *slog.Logger, w http.ResponseWriter, status int, publicMsg string, err error) {
	logger.Error(publicMsg, "error", err)
	WriteError(w, status, publicMsg)
}

// RequireNonEmpty writes a 400 "<field> is required" error when value is blank after trimming,
// and reports whether validation passed so the caller can return immediately when it fails.
func RequireNonEmpty(w http.ResponseWriter, field, value string) bool {
	if strings.TrimSpace(value) == "" {
		WriteError(w, http.StatusBadRequest, field+" is required")
		return false
	}

	return true
}

// MethodNotAllowed responds with 204 for OPTIONS or 405 for other unsupported methods.
func MethodNotAllowed(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	WriteError(w, http.StatusMethodNotAllowed, "method not allowed")
}
