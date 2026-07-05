package api

import (
	"errors"
	"net/http"

	"github.com/enegalan/calf/backend/internal/runtime"
)

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
