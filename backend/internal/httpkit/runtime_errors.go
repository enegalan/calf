package httpkit

import (
	"errors"
	"net/http"

	"github.com/enegalan/calf/backend/internal/runtime"
)

// WriteRuntimeError maps known runtime errors to HTTP responses and reports whether err was handled.
func WriteRuntimeError(w http.ResponseWriter, err error) bool {
	if errors.Is(err, runtime.ErrRuntimeNotRunning) {
		WriteError(w, http.StatusServiceUnavailable, "runtime is not running")
		return true
	}

	if errors.Is(err, runtime.ErrNetworkNotFound) {
		WriteError(w, http.StatusNotFound, "network not found")
		return true
	}

	return false
}

// WriteRuntimeOrFail writes a mapped runtime error or a generic 500 for unhandled errors.
func WriteRuntimeOrFail(w http.ResponseWriter, err error) {
	if WriteRuntimeError(w, err) {
		return
	}

	WriteError(w, http.StatusInternalServerError, "operation failed")
}
