package api

import (
	"net/http"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/httpkit"
)

// handleRuntimeStart serves POST /v1/runtime/start and boots the container runtime.
func (g *Gateway) handleRuntimeStart(w http.ResponseWriter, r *http.Request) {
	r, cancel := httpkit.WithTimeout(r, constants.RuntimeActionTimeout)
	defer cancel()

	if err := g.backend.EnsureRuntimeRunning(r.Context()); err != nil {
		g.logger.Error("runtime start failed", "error", err)
		httpkit.WriteError(w, http.StatusServiceUnavailable, "failed to start the container runtime")
		return
	}
	status, err := g.backend.Runtime.Status(r.Context())
	if err != nil {
		httpkit.WriteLoggedError(g.logger, w, http.StatusInternalServerError, "failed to read runtime status", err)
		return
	}
	httpkit.WriteJSON(w, http.StatusOK, status)
}

// handleRuntimeStop serves POST /v1/runtime/stop and POST /v1/runtime/kill, both of which
// force-stop the container runtime. Always tears the engine down; vm_keep_alive only applies
// when the daemon itself quits.
func (g *Gateway) handleRuntimeStop(w http.ResponseWriter, r *http.Request) {
	r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
	defer cancel()

	if err := g.backend.Runtime.ForceStop(r.Context()); err != nil {
		httpkit.WriteLoggedError(g.logger, w, http.StatusInternalServerError, "failed to stop the container runtime", err)
		return
	}
	g.backend.ClearResourceSaver()
	status, err := g.backend.Runtime.Status(r.Context())
	if err != nil {
		httpkit.WriteLoggedError(g.logger, w, http.StatusInternalServerError, "failed to read runtime status", err)
		return
	}
	httpkit.WriteJSON(w, http.StatusOK, status)
}
