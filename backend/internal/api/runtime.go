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

	if err := g.backend.ForceStopRuntime(ctx); err != nil {
		httpkit.WriteError(w, http.StatusInternalServerError, err.Error())
		return
	}
	g.backend.ClearResourceSaver()
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

	if err := g.backend.ForceStopRuntime(ctx); err != nil {
		httpkit.WriteError(w, http.StatusInternalServerError, err.Error())
		return
	}
	g.backend.ClearResourceSaver()
	status, err := g.backend.Runtime.Status(ctx)
	if err != nil {
		httpkit.WriteError(w, http.StatusInternalServerError, err.Error())
		return
	}
	httpkit.WriteJSON(w, http.StatusOK, status)
}
