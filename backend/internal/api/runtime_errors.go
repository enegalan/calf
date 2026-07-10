package api

import (
	"errors"
	"net/http"

	"github.com/enegalan/calf/backend/internal/runtime"
)

// writeRuntimeError maps known runtime errors to HTTP responses and reports whether err was handled.
func writeRuntimeError(w http.ResponseWriter, err error) bool {
	if errors.Is(err, runtime.ErrRuntimeNotRunning) {
		writeError(w, http.StatusServiceUnavailable, "runtime is not running")
		return true
	}

	if errors.Is(err, runtime.ErrNetworkNotFound) {
		writeError(w, http.StatusNotFound, "network not found")
		return true
	}

	return false
}

// writeRuntimeOrFail writes a mapped runtime error or a generic 500 for unhandled errors.
func writeRuntimeOrFail(w http.ResponseWriter, err error) {
	if writeRuntimeError(w, err) {
		return
	}

	writeError(w, http.StatusInternalServerError, err.Error())
}
