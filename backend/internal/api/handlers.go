package api

import (
	"context"
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
	PollIntervalMs       int    `json:"poll_interval_ms"`
	CPUs                 int    `json:"cpus"`
	MemoryGB             int    `json:"memory_gb"`
	MemorySwapGB         int    `json:"memory_swap_gb"`
	HostCPUs             int    `json:"host_cpus"`
	HostMemoryGB         int    `json:"host_memory_gb"`
	DockerContextManaged bool   `json:"docker_context_managed"`
	DockerContextActive  bool   `json:"docker_context_active"`
	DockerContextName    string `json:"docker_context_name"`
	DockerCLIAvailable   bool   `json:"docker_cli_available"`
}

type configUpdateRequest struct {
	CPUs                 *int  `json:"cpus,omitempty"`
	MemoryGB             *int  `json:"memory_gb,omitempty"`
	MemorySwapGB         *int  `json:"memory_swap_gb,omitempty"`
	DockerContextManaged *bool `json:"docker_context_managed,omitempty"`
}

func (s *Server) handleConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, s.configResponse())

	case http.MethodPut:
		var req configUpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
			return
		}

		s.cfgMu.Lock()
		if req.CPUs != nil {
			s.cfg.CPUs = *req.CPUs
		}
		if req.MemoryGB != nil {
			s.cfg.MemoryGB = *req.MemoryGB
		}
		if req.MemorySwapGB != nil {
			s.cfg.MemorySwapGB = *req.MemorySwapGB
		}
		if req.DockerContextManaged != nil {
			s.cfg.DockerContextManaged = *req.DockerContextManaged
		}

		if err := config.Save(s.cfg); err != nil {
			s.cfgMu.Unlock()
			writeError(w, http.StatusInternalServerError, "failed to save config: "+err.Error())
			return
		}

		activateManaged := s.cfg.DockerContextManaged
		s.cfgMu.Unlock()

		if activateManaged {
			activateCtx, cancel := context.WithTimeout(r.Context(), dockerContextTimeout)
			defer cancel()
			if err := s.activateDockerContext(activateCtx); err != nil {
				s.logger.Warn("failed to activate docker context", "error", err)
			}
		}

		writeJSON(w, http.StatusOK, s.configResponse())

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

func (s *Server) configResponse() configResponse {
	cliStatus, _ := s.dockerCLIStatus()

	s.cfgMu.RLock()
	cfg := s.cfg
	s.cfgMu.RUnlock()

	return configResponse{
		PollIntervalMs:       cfg.PollIntervalMs,
		CPUs:                 cfg.CPUs,
		MemoryGB:             cfg.MemoryGB,
		MemorySwapGB:         cfg.MemorySwapGB,
		HostCPUs:             hostCPUs(),
		HostMemoryGB:         hostMemoryGB(),
		DockerContextManaged: cfg.DockerContextManaged,
		DockerContextActive:  cliStatus.CalfActive,
		DockerContextName:    cliStatus.CurrentContext,
		DockerCLIAvailable:   cliStatus.Available,
	}
}
