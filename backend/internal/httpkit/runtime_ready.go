package httpkit

import (
	"context"
	"net/http"

	"github.com/enegalan/calf/backend/internal/daemon"
)

// EnsureRuntimeOrFail ensures the runtime is running and writes an error response on failure.
func EnsureRuntimeOrFail(w http.ResponseWriter, ctx context.Context, backend *daemon.Core) bool {
	if err := backend.EnsureRuntimeRunning(ctx); err != nil {
		if WriteRuntimeError(w, err) {
			return false
		}

		WriteError(w, http.StatusServiceUnavailable, err.Error())
		return false
	}

	return true
}
