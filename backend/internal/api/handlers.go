package api

import (
	"encoding/json"
	"net/http"
	"time"
)

type healthResponse struct {
	Status string `json:"status"`
}

type statusResponse struct {
	Version       string `json:"version"`
	UptimeSeconds int64  `json:"uptime_seconds"`
	ListenAddr    string `json:"listen_addr"`
	LogLevel      string `json:"log_level"`
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

	writeJSON(w, http.StatusOK, statusResponse{
		Version:       Version,
		UptimeSeconds: int64(time.Since(s.startTime).Seconds()),
		ListenAddr:    s.cfg.ListenAddr,
		LogLevel:      s.cfg.LogLevel,
	})
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
