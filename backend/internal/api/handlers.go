package api

import (
	"net/http"
	"time"

	"github.com/enegalan/calf/backend/internal/runtime"
)

type healthResponse struct {
	Status string `json:"status"`
}

type statusResponse struct {
	Version       string          `json:"version"`
	UptimeSeconds int64           `json:"uptime_seconds"`
	ListenAddr    string          `json:"listen_addr"`
	LogLevel      string          `json:"log_level"`
	Runtime       runtime.Status  `json:"runtime"`
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	writeJSON(w, http.StatusOK, healthResponse{Status: "ok"})
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	runtimeStatus, err := s.runtime.Status(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, statusResponse{
		Version:       Version,
		UptimeSeconds: int64(time.Since(s.startTime).Seconds()),
		ListenAddr:    s.cfg.ListenAddr,
		LogLevel:      s.cfg.LogLevel,
		Runtime:       runtimeStatus,
	})
}
