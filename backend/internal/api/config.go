package api

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/daemon"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// configView represents the JSON payload for GET /v1/config.
type configView struct {
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
	Rootless             bool   `json:"rootless"`
	HTTPProxy            string `json:"http_proxy"`
	HTTPSProxy           string `json:"https_proxy"`
	NoProxy              string `json:"no_proxy"`
}

// buildConfigView builds the JSON payload for GET /v1/config including host capacity and Docker CLI status.
func (g *Gateway) buildConfigView() configView {
	cliStatus, _ := g.backend.DockerCLI.Status()

	g.backend.CfgMu.RLock()
	cfg := g.backend.Cfg
	g.backend.CfgMu.RUnlock()

	return configView{
		PollIntervalMs:       cfg.PollIntervalMs,
		CPUs:                 cfg.CPUs,
		MemoryGB:             cfg.MemoryGB,
		MemorySwapGB:         cfg.MemorySwapGB,
		HostCPUs:             daemon.HostCPUs(),
		HostMemoryGB:         daemon.HostMemoryGB(),
		DockerContextManaged: cfg.DockerContextManaged,
		DockerContextActive:  cliStatus.CalfActive,
		DockerContextName:    cliStatus.CurrentContext,
		DockerCLIAvailable:   cliStatus.Available,
		Rootless:             cfg.Rootless,
		HTTPProxy:            cfg.HTTPProxy,
		HTTPSProxy:           cfg.HTTPSProxy,
		NoProxy:              cfg.NoProxy,
	}
}

// applyConfigUpdate merges validated config update fields into the daemon config and persists them.
func (g *Gateway) applyConfigUpdate(req config.UpdateRequest) (config.Config, error) {
	g.backend.CfgMu.Lock()
	defer g.backend.CfgMu.Unlock()

	if req.CPUs != nil {
		g.backend.Cfg.CPUs = *req.CPUs
	}
	if req.MemoryGB != nil {
		g.backend.Cfg.MemoryGB = *req.MemoryGB
	}
	if req.MemorySwapGB != nil {
		g.backend.Cfg.MemorySwapGB = *req.MemorySwapGB
	}
	if req.DockerContextManaged != nil {
		g.backend.Cfg.DockerContextManaged = *req.DockerContextManaged
	}
	if req.Rootless != nil {
		g.backend.Cfg.Rootless = *req.Rootless
	}
	if req.HTTPProxy != nil {
		g.backend.Cfg.HTTPProxy = strings.TrimSpace(*req.HTTPProxy)
	}
	if req.HTTPSProxy != nil {
		g.backend.Cfg.HTTPSProxy = strings.TrimSpace(*req.HTTPSProxy)
	}
	if req.NoProxy != nil {
		g.backend.Cfg.NoProxy = strings.TrimSpace(*req.NoProxy)
	}

	if err := config.Save(g.backend.Cfg); err != nil {
		return config.Config{}, err
	}

	return g.backend.Cfg, nil
}

// handleConfigGet serves GET /v1/config.
func (g *Gateway) handleConfigGet(w http.ResponseWriter, r *http.Request) {
	httpkit.WriteJSON(w, http.StatusOK, g.buildConfigView())
}

// handleConfigPut serves PUT /v1/config.
func (g *Gateway) handleConfigPut(w http.ResponseWriter, r *http.Request) {
	var req config.UpdateRequest
	if err := httpkit.JSONDecode(r, &req); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}

	if err := config.ValidateProxyUpdate(req); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	if err := config.ValidateResourceUpdate(req, daemon.HostCPUs(), daemon.HostMemoryGB()); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	if req.Rootless != nil {
		g.backend.CfgMu.RLock()
		currentRootless := g.backend.Cfg.Rootless
		g.backend.CfgMu.RUnlock()
		if *req.Rootless != currentRootless {
			if _, isNative := g.backend.Runtime.(*runtime.Native); isNative {
				httpkit.WriteError(w, http.StatusConflict, "changing rootless requires restarting the Calf daemon")
				return
			}
		}
	}

	proxyChanged := req.HTTPProxy != nil || req.HTTPSProxy != nil || req.NoProxy != nil
	saved, err := g.applyConfigUpdate(req)
	if err != nil {
		httpkit.WriteError(w, http.StatusInternalServerError, "failed to save config: "+err.Error())
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, g.buildConfigView())

	if proxyChanged {
		go func() {
			proxyCfg := runtime.ProxyConfig{
				HTTPProxy:  saved.HTTPProxy,
				HTTPSProxy: saved.HTTPSProxy,
				NoProxy:    saved.NoProxy,
			}
			proxyCtx, cancel := context.WithTimeout(g.backend.Lifecycle(), constants.DockerCLITimeout)
			defer cancel()
			if err := g.backend.Runtime.ApplyProxy(proxyCtx, proxyCfg); err != nil {
				if errors.Is(err, context.Canceled) {
					return
				}
				if !errors.Is(err, runtime.ErrRuntimeNotRunning) {
					g.logger.Warn("failed to apply proxy settings", "error", err)
					return
				}
				if startErr := g.backend.EnsureRuntimeRunning(proxyCtx); startErr != nil {
					if errors.Is(startErr, context.Canceled) {
						return
					}
					g.logger.Warn("failed to start runtime for proxy settings", "error", startErr)
					return
				}
				if err := g.backend.Runtime.ApplyProxy(proxyCtx, proxyCfg); err != nil {
					if errors.Is(err, context.Canceled) {
						return
					}
					g.logger.Warn("failed to apply proxy settings after runtime start", "error", err)
				}
			}
		}()
	}

	if saved.DockerContextManaged {
		activateCtx, cancel := context.WithTimeout(g.backend.Lifecycle(), constants.DefaultActionTimeout)
		defer cancel()
		if err := g.backend.DockerCLI.Activate(activateCtx); err != nil {
			if errors.Is(err, context.Canceled) {
				return
			}
			g.logger.Warn("failed to activate docker context", "error", err)
		}
	}
}
