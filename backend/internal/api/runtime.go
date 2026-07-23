package api

import (
	"context"
	"net/http"

	"github.com/enegalan/calf/backend/internal/constants"
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

// handleRuntimeStop serves POST /v1/runtime/stop and stops the container runtime.
// Always tears the engine down; vm_keep_alive only applies when the daemon itself quits.
func (g *Gateway) handleRuntimeStop(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), constants.DefaultActionTimeout)
	defer cancel()

	if err := g.backend.Runtime.ForceStop(ctx); err != nil {
		httpkit.WriteError(w, http.StatusInternalServerError, err.Error())
		return
	}
	status, err := g.backend.Runtime.Status(ctx)
	if err != nil {
		httpkit.WriteError(w, http.StatusInternalServerError, err.Error())
		return
	}
	httpkit.WriteJSON(w, http.StatusOK, status)
}

// handleRuntimeKill serves POST /v1/runtime/kill and force-stops the container runtime.
func (g *Gateway) handleRuntimeKill(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), constants.DefaultActionTimeout)
	defer cancel()

	if err := g.backend.Runtime.ForceStop(ctx); err != nil {
		httpkit.WriteError(w, http.StatusInternalServerError, err.Error())
		return
	}
	status, err := g.backend.Runtime.Status(ctx)
	if err != nil {
		httpkit.WriteError(w, http.StatusInternalServerError, err.Error())
		return
	}
	httpkit.WriteJSON(w, http.StatusOK, status)
}
