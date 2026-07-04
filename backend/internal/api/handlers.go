package api

import (
	"encoding/json"
	goruntime "runtime"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/version"
)

func hostCPUs() int {
	return goruntime.NumCPU()
}

func hostMemoryGB() int {
	out, err := exec.Command("sysctl", "-n", "hw.memsize").Output()
	if err != nil {
		return 8
	}
	bytes, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	if err != nil {
		return 8
	}
	gb := int(bytes / (1024 * 1024 * 1024))
	if gb < 1 {
		return 1
	}
	return gb
}

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

type configResponse struct {
	PollIntervalMs int `json:"poll_interval_ms"`
	CPUs           int `json:"cpus"`
	MemoryGB       int `json:"memory_gb"`
	MemorySwapGB   int `json:"memory_swap_gb"`
	HostCPUs       int `json:"host_cpus"`
	HostMemoryGB   int `json:"host_memory_gb"`
}

type configUpdateRequest struct {
	CPUs         *int `json:"cpus,omitempty"`
	MemoryGB     *int `json:"memory_gb,omitempty"`
	MemorySwapGB *int `json:"memory_swap_gb,omitempty"`
}

func (s *Server) handleConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, configResponse{
			PollIntervalMs: s.cfg.PollIntervalMs,
			CPUs:           s.cfg.CPUs,
			MemoryGB:       s.cfg.MemoryGB,
			MemorySwapGB:   s.cfg.MemorySwapGB,
			HostCPUs:       hostCPUs(),
			HostMemoryGB:   hostMemoryGB(),
		})

	case http.MethodPut:
		var req configUpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
			return
		}

		if req.CPUs != nil {
			s.cfg.CPUs = *req.CPUs
		}
		if req.MemoryGB != nil {
			s.cfg.MemoryGB = *req.MemoryGB
		}
		if req.MemorySwapGB != nil {
			s.cfg.MemorySwapGB = *req.MemorySwapGB
		}

		if err := config.Save(s.cfg); err != nil {
			writeError(w, http.StatusInternalServerError, "failed to save config: "+err.Error())
			return
		}

		writeJSON(w, http.StatusOK, configResponse{
			PollIntervalMs: s.cfg.PollIntervalMs,
			CPUs:           s.cfg.CPUs,
			MemoryGB:       s.cfg.MemoryGB,
			MemorySwapGB:   s.cfg.MemorySwapGB,
			HostCPUs:       hostCPUs(),
			HostMemoryGB:   hostMemoryGB(),
		})

	default:
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
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
		Version:       version.Version,
		UptimeSeconds: int64(time.Since(s.startTime).Seconds()),
		ListenAddr:    s.cfg.ListenAddr,
		LogLevel:      s.cfg.LogLevel,
		Runtime:       runtimeStatus,
	})
}
