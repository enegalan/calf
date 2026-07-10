package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	goruntime "runtime"
	"strconv"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
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
	Version       string         `json:"version"`
	UptimeSeconds int64          `json:"uptime_seconds"`
	ListenAddr    string         `json:"listen_addr"`
	LogLevel      string         `json:"log_level"`
	Runtime       runtime.Status `json:"runtime"`
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
	HTTPProxy            string `json:"http_proxy"`
	HTTPSProxy           string `json:"https_proxy"`
	NoProxy              string `json:"no_proxy"`
}

type configUpdateRequest struct {
	CPUs                 *int    `json:"cpus,omitempty"`
	MemoryGB             *int    `json:"memory_gb,omitempty"`
	MemorySwapGB         *int    `json:"memory_swap_gb,omitempty"`
	DockerContextManaged *bool   `json:"docker_context_managed,omitempty"`
	HTTPProxy            *string `json:"http_proxy,omitempty"`
	HTTPSProxy           *string `json:"https_proxy,omitempty"`
	NoProxy              *string `json:"no_proxy,omitempty"`
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

		if err := validateProxyUpdate(req); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
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
		if req.HTTPProxy != nil {
			s.cfg.HTTPProxy = strings.TrimSpace(*req.HTTPProxy)
		}
		if req.HTTPSProxy != nil {
			s.cfg.HTTPSProxy = strings.TrimSpace(*req.HTTPSProxy)
		}
		if req.NoProxy != nil {
			s.cfg.NoProxy = strings.TrimSpace(*req.NoProxy)
		}

		proxyChanged := req.HTTPProxy != nil || req.HTTPSProxy != nil || req.NoProxy != nil
		savedProxy := runtime.ProxyConfig{
			HTTPProxy:  s.cfg.HTTPProxy,
			HTTPSProxy: s.cfg.HTTPSProxy,
			NoProxy:    s.cfg.NoProxy,
		}

		if err := config.Save(s.cfg); err != nil {
			s.cfgMu.Unlock()
			writeError(w, http.StatusInternalServerError, "failed to save config: "+err.Error())
			return
		}

		activateManaged := s.cfg.DockerContextManaged
		s.cfgMu.Unlock()

		writeJSON(w, http.StatusOK, s.configResponse())

		if proxyChanged {
			go func() {
				proxyCtx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
				defer cancel()
				if err := s.runtime.ApplyProxy(proxyCtx, savedProxy); err != nil {
					s.logger.Warn("failed to apply proxy settings", "error", err)
				}
			}()
		}

		if activateManaged {
			activateCtx, cancel := context.WithTimeout(context.Background(), constants.DefaultActionTimeout)
			defer cancel()
			if err := s.activateDockerContext(activateCtx); err != nil {
				s.logger.Warn("failed to activate docker context", "error", err)
			}
		}

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

func validateProxyUpdate(req configUpdateRequest) error {
	if req.HTTPProxy != nil {
		v := strings.TrimSpace(*req.HTTPProxy)
		if v != "" {
			if err := validateProxyURL(v, "http"); err != nil {
				return fmt.Errorf("http_proxy: %w", err)
			}
		}
	}
	if req.HTTPSProxy != nil {
		v := strings.TrimSpace(*req.HTTPSProxy)
		if v != "" {
			if err := validateProxyURL(v, "http", "https"); err != nil {
				return fmt.Errorf("https_proxy: %w", err)
			}
		}
	}
	if req.NoProxy != nil {
		v := strings.TrimSpace(*req.NoProxy)
		if v != "" {
			for _, entry := range strings.Split(v, ",") {
				entry = strings.TrimSpace(entry)
				if entry != "" {
					if err := validateNoProxyEntry(entry); err != nil {
						return fmt.Errorf("no_proxy: %w", err)
					}
				}
			}
		}
	}
	return nil
}

func validateProxyURL(raw string, allowedSchemes ...string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("invalid URL %q: %w", raw, err)
	}

	if u.Scheme == "" {
		return fmt.Errorf("missing scheme in %q (expected http:// or https://)", raw)
	}

	schemeOK := false
	for _, s := range allowedSchemes {
		if u.Scheme == s {
			schemeOK = true
			break
		}
	}
	if !schemeOK {
		return fmt.Errorf("unsupported scheme %q in %q", u.Scheme, raw)
	}

	if u.Host == "" {
		return fmt.Errorf("missing host in %q", raw)
	}

	return nil
}

func validateNoProxyEntry(entry string) error {
	if strings.Contains(entry, "/") {
		return fmt.Errorf("invalid no_proxy entry %q: must not contain a path", entry)
	}

	host := entry
	if strings.HasPrefix(host, ".") {
		host = host[1:]
	}

	if net.ParseIP(host) != nil {
		return nil
	}

	if h, _, err := net.SplitHostPort(host); err == nil {
		if net.ParseIP(h) != nil {
			return nil
		}
		host = h
	}

	if isValidDomain(host) {
		return nil
	}

	return fmt.Errorf("invalid no_proxy entry %q: must be a valid hostname or IP address", entry)
}

func isValidDomain(host string) bool {
	if host == "" || len(host) > 253 {
		return false
	}

	for _, part := range strings.Split(host, ".") {
		if part == "" || len(part) > 63 {
			return false
		}
		for i, r := range part {
			if i == 0 && r == '-' {
				return false
			}
			if i == len(part)-1 && r == '-' {
				return false
			}
			if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
				(r >= '0' && r <= '9') || r == '-' || r == '_') {
				return false
			}
		}
	}

	return true
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
		HTTPProxy:            cfg.HTTPProxy,
		HTTPSProxy:           cfg.HTTPSProxy,
		NoProxy:              cfg.NoProxy,
	}
}
