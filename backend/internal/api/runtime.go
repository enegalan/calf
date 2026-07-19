package api

import (
	"net/http"

	"github.com/enegalan/calf/backend/internal/httpkit"
)

// handleRuntimeStart serves POST /v1/runtime/start and boots the container runtime.
func (g *Gateway) handleRuntimeStart(w http.ResponseWriter, r *http.Request) {
	if err := g.backend.EnsureRuntimeRunning(r.Context()); err != nil {
		httpkit.WriteError(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	status, err := g.backend.Runtime.Status(r.Context())
	if err != nil {
		httpkit.WriteError(w, http.StatusInternalServerError, err.Error())
		return
	}
	httpkit.WriteJSON(w, http.StatusOK, status)
}
