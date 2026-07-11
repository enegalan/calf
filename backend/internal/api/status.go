package api

import (
	"net/http"
	"time"

	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/version"
)

type statusResponse struct {
	Version       string         `json:"version"`
	UptimeSeconds int64          `json:"uptime_seconds"`
	ListenAddr    string         `json:"listen_addr"`
	LogLevel      string         `json:"log_level"`
	Runtime       runtime.Status `json:"runtime"`
}

// handleStatus serves GET /v1/status with version, uptime, and runtime state.
func (g *Gateway) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		httpkit.WriteError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	runtimeStatus, err := g.backend.Runtime.Status(r.Context())
	if err != nil {
		httpkit.WriteError(w, http.StatusInternalServerError, err.Error())
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, statusResponse{
		Version:       version.Version,
		UptimeSeconds: int64(time.Since(g.backend.StartTime).Seconds()),
		ListenAddr:    g.backend.Cfg.ListenAddr,
		LogLevel:      g.backend.Cfg.LogLevel,
		Runtime:       runtimeStatus,
	})
}
