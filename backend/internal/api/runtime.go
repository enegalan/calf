package api

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/httpkit"
)

// handleRuntimeStart serves POST /v1/runtime/start and boots the container runtime.
func (g *Gateway) handleRuntimeStart(w http.ResponseWriter, r *http.Request) {
	r, cancel := httpkit.WithTimeout(r, constants.RuntimeActionTimeout)
	defer cancel()

	if err := g.backend.EnsureRuntimeRunning(r.Context()); err != nil {
		g.logger.Error("runtime start failed", "error", err)
		msg := "failed to start the container runtime"
		errText := err.Error()
		switch {
		case strings.Contains(errText, "guest disk missing"),
			strings.Contains(errText, "no GitHub release asset"),
			strings.Contains(errText, "not enough free disk space"),
			strings.Contains(errText, "krunkit not found"),
			strings.Contains(errText, "gvproxy not found"),
			strings.Contains(errText, "docker CLI not found"):
			msg = errText
		case errors.Is(err, context.DeadlineExceeded):
			msg = "timed out starting the container runtime"
		case errors.Is(err, context.Canceled):
			msg = "container runtime start was canceled"
		}
		httpkit.WriteError(w, http.StatusServiceUnavailable, msg)
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

	if err := g.backend.ForceStopRuntime(r.Context()); err != nil {
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
