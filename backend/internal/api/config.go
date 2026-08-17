package api

import (
	"context"
	"errors"
	"net/http"
	"os"
	"strings"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/daemon"
	"github.com/enegalan/calf/backend/internal/dockercli"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// configView represents the JSON payload for GET /v1/config.
type configView struct {
	PollIntervalMs          int                       `json:"poll_interval_ms"`
	CPUs                    int                       `json:"cpus"`
	MemoryGB                int                       `json:"memory_gb"`
	MemorySwapGB            int                       `json:"memory_swap_gb"`
	DiskGB                  int                       `json:"disk_gb"`
	DiskImage               string                    `json:"disk_image"`
	HostCPUs                int                       `json:"host_cpus"`
	HostMemoryGB            int                       `json:"host_memory_gb"`
	HostDiskGB              int                       `json:"host_disk_gb"`
	DockerContextManaged    bool                      `json:"docker_context_managed"`
	DockerContextActive     bool                      `json:"docker_context_active"`
	DockerContextName       string                    `json:"docker_context_name"`
	DockerCLIAvailable      bool                      `json:"docker_cli_available"`
	DockerBuildxAvailable   bool                      `json:"docker_buildx_available"`
	DockerComposeAvailable  bool                      `json:"docker_compose_available"`
	DockerPluginsHint       string                    `json:"docker_plugins_hint,omitempty"`
	HijackWarnings          []dockercli.HijackWarning `json:"hijack_warnings,omitempty"`
	DefaultSocketEnabled    bool                      `json:"default_socket_enabled"`
	DefaultSocketHint       string                    `json:"default_socket_hint,omitempty"`
	Rootless                bool                      `json:"rootless"`
	HTTPProxy               string                    `json:"http_proxy"`
	HTTPSProxy              string                    `json:"https_proxy"`
	NoProxy                 string                    `json:"no_proxy"`
	ResourceSaverEnabled    bool                      `json:"resource_saver_enabled"`
	ResourceSaverTimeoutSec int                       `json:"resource_saver_timeout_sec"`
	LogLevel                string                    `json:"log_level"`
	ShellCompletions        bool                      `json:"shell_completions"`
	DefaultDockerSocket     bool                      `json:"default_docker_socket"`
	PrivilegedPorts         bool                      `json:"privileged_ports"`
	FileShares              []string                  `json:"file_shares"`
	HostNetworking          bool                      `json:"host_networking"`
	DaemonJSON              string                    `json:"daemon_json"`
	DockerSubnet            string                    `json:"docker_subnet"`
	BindLocalhostOnly       bool                      `json:"bind_localhost_only"`
	EnableAmd64Emulation    bool                      `json:"enable_amd64_emulation"`
	DockerBuildxVersion     string                    `json:"docker_buildx_version,omitempty"`
	DockerComposeVersion    string                    `json:"docker_compose_version,omitempty"`
}

// buildConfigView builds the JSON payload for GET /v1/config including host capacity and Docker CLI status.
func (g *Gateway) buildConfigView() configView {
	cliStatus, _ := g.backend.DockerCLI.Status()

	g.backend.CfgMu.RLock()
	cfg := g.backend.Cfg
	g.backend.CfgMu.RUnlock()

	hostDiskGB := daemon.HostDiskGB()
	if cfg.DiskGB > hostDiskGB {
		hostDiskGB = cfg.DiskGB
	}

	return configView{
		PollIntervalMs:          cfg.PollIntervalMs,
		CPUs:                    cfg.CPUs,
		MemoryGB:                cfg.MemoryGB,
		MemorySwapGB:            cfg.MemorySwapGB,
		DiskGB:                  cfg.DiskGB,
		DiskImage:               config.EffectiveDiskImage(cfg),
		HostCPUs:                daemon.HostCPUs(),
		HostMemoryGB:            daemon.HostMemoryGB(),
		HostDiskGB:              hostDiskGB,
		DockerContextManaged:    cfg.DockerContextManaged,
		DockerContextActive:     cliStatus.CalfActive,
		DockerContextName:       cliStatus.CurrentContext,
		DockerCLIAvailable:      cliStatus.Available,
		DockerBuildxAvailable:   cliStatus.BuildxAvailable,
		DockerComposeAvailable:  cliStatus.ComposeAvailable,
		DockerPluginsHint:       cliStatus.PluginsHint,
		HijackWarnings:          cliStatus.HijackWarnings,
		DefaultSocketEnabled:    cliStatus.DefaultSocket.Enabled,
		DefaultSocketHint:       cliStatus.DefaultSocket.Hint,
		Rootless:                cfg.Rootless,
		HTTPProxy:               cfg.HTTPProxy,
		HTTPSProxy:              cfg.HTTPSProxy,
		NoProxy:                 cfg.NoProxy,
		ResourceSaverEnabled:    cfg.ResourceSaverEnabled,
		ResourceSaverTimeoutSec: cfg.ResourceSaverTimeoutSec,
		LogLevel:                cfg.LogLevel,
		ShellCompletions:        cfg.ShellCompletions,
		DefaultDockerSocket:     cfg.DefaultDockerSocket,
		PrivilegedPorts:         cfg.PrivilegedPorts,
		FileShares:              cfg.FileShares,
		HostNetworking:          cfg.HostNetworking,
		DaemonJSON:              cfg.DaemonJSON,
		DockerSubnet:            cfg.DockerSubnet,
		BindLocalhostOnly:       cfg.BindLocalhostOnly,
		EnableAmd64Emulation:    cfg.EnableAmd64Emulation,
		DockerBuildxVersion:     cliStatus.BuildxVersion,
		DockerComposeVersion:    cliStatus.ComposeVersion,
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
	if req.DiskGB != nil {
		g.backend.Cfg.DiskGB = *req.DiskGB
	}
	if req.DiskImage != nil {
		path := strings.TrimSpace(*req.DiskImage)
		if path == "" {
			g.backend.Cfg.DiskImage = ""
		} else {
			expanded := config.ExpandHomePath(path)
			defaultPath := config.DefaultDiskImagePath(g.backend.Cfg.VMName)
			if expanded == defaultPath {
				g.backend.Cfg.DiskImage = ""
			} else {
				g.backend.Cfg.DiskImage = expanded
			}
		}
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
	if req.ResourceSaverEnabled != nil {
		g.backend.Cfg.ResourceSaverEnabled = *req.ResourceSaverEnabled
	}
	if req.ResourceSaverTimeoutSec != nil {
		g.backend.Cfg.ResourceSaverTimeoutSec = *req.ResourceSaverTimeoutSec
	}
	if req.LogLevel != nil {
		normalized, err := config.NormalizeLogLevel(*req.LogLevel)
		if err != nil {
			return config.Config{}, err
		}
		g.backend.Cfg.LogLevel = normalized
		config.SetLogLevel(normalized)
		g.backend.Logger.Info("log level updated", "level", normalized)
	}
	if req.ShellCompletions != nil {
		g.backend.Cfg.ShellCompletions = *req.ShellCompletions
	}
	if req.DefaultDockerSocket != nil {
		g.backend.Cfg.DefaultDockerSocket = *req.DefaultDockerSocket
	}
	if req.PrivilegedPorts != nil {
		g.backend.Cfg.PrivilegedPorts = *req.PrivilegedPorts
	}
	if req.FileShares != nil {
		g.backend.Cfg.FileShares = *req.FileShares
	}
	if req.HostNetworking != nil {
		g.backend.Cfg.HostNetworking = *req.HostNetworking
	}
	if req.DaemonJSON != nil {
		g.backend.Cfg.DaemonJSON = strings.TrimSpace(*req.DaemonJSON)
	}
	if req.DockerSubnet != nil {
		g.backend.Cfg.DockerSubnet = strings.TrimSpace(*req.DockerSubnet)
	}
	if req.BindLocalhostOnly != nil {
		g.backend.Cfg.BindLocalhostOnly = *req.BindLocalhostOnly
	}
	if req.EnableAmd64Emulation != nil {
		g.backend.Cfg.EnableAmd64Emulation = *req.EnableAmd64Emulation
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
	if req.LogLevel != nil {
		if _, err := config.NormalizeLogLevel(*req.LogLevel); err != nil {
			httpkit.WriteError(w, http.StatusBadRequest, err.Error())
			return
		}
	}

	hostDiskGB := daemon.HostDiskGB()
	g.backend.CfgMu.RLock()
	if g.backend.Cfg.DiskGB > hostDiskGB {
		hostDiskGB = g.backend.Cfg.DiskGB
	}
	g.backend.CfgMu.RUnlock()
	if err := config.ValidateResourceUpdate(req, daemon.HostCPUs(), daemon.HostMemoryGB(), hostDiskGB); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	if req.Rootless != nil {
		g.backend.CfgMu.RLock()
		currentRootless := g.backend.Cfg.Rootless
		g.backend.CfgMu.RUnlock()
		if *req.Rootless != currentRootless {
			if _, isNative := g.backend.Runtime.(*runtime.Native); isNative {
				httpkit.WriteError(w, http.StatusConflict, "changing rootless requires restarting the calf daemon")
				return
			}
		}
	}

	g.backend.CfgMu.RLock()
	proxyChanged := config.ProxyUpdateChanged(req, g.backend.Cfg)
	g.backend.CfgMu.RUnlock()
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

	if req.DockerContextManaged != nil && !saved.DockerContextManaged {
		deactivateCtx, cancel := context.WithTimeout(g.backend.Lifecycle(), constants.DefaultActionTimeout)
		defer cancel()
		if err := g.backend.DockerCLI.Deactivate(deactivateCtx); err != nil {
			if errors.Is(err, context.Canceled) {
				return
			}
			g.logger.Warn("failed to deactivate docker context", "error", err)
		}
	} else if saved.DockerContextManaged {
		activateCtx, cancel := context.WithTimeout(g.backend.Lifecycle(), constants.DefaultActionTimeout)
		defer cancel()
		if err := g.backend.DockerCLI.Activate(activateCtx); err != nil {
			if errors.Is(err, context.Canceled) {
				return
			}
			g.logger.Warn("failed to activate docker context", "error", err)
		}
	}

	if req.ShellCompletions != nil {
		if saved.ShellCompletions {
			if err := dockercli.EnsureShellCompletions(); err != nil {
				g.logger.Warn("failed to write shell completions", "error", err)
			}
		} else {
			if err := dockercli.RemoveShellCompletions(); err != nil {
				g.logger.Warn("failed to remove shell completions", "error", err)
			}
		}
	}
	if req.DefaultDockerSocket != nil {
		if saved.DefaultDockerSocket {
			if err := dockercli.EnableDefaultSocket(g.backend.Runtime.DockerSocket()); err != nil {
				g.logger.Warn("failed to enable default docker socket", "error", err)
			}
		} else {
			if err := dockercli.DisableDefaultSocket(g.backend.Runtime.DockerSocket()); err != nil {
				g.logger.Warn("failed to disable default docker socket", "error", err)
			}
		}
	}
	if req.PrivilegedPorts != nil && saved.PrivilegedPorts {
		if exe, err := os.Executable(); err == nil {
			if err := dockercli.InstallPrivilegedHelper(exe); err != nil {
				g.logger.Warn("failed to install privileged ports helper", "error", err)
			}
		}
	}
	g.backend.Runtime.ApplyEngineSettings(engineSettingsFrom(saved))
}

// engineSettingsFrom copies guest overlay fields from persisted config.
func engineSettingsFrom(cfg config.Config) runtime.EngineSettings {
	shares := cfg.FileShares
	if shares == nil {
		shares = []string{}
	}
	return runtime.EngineSettings{
		FileShares:           shares,
		HostNetworking:       cfg.HostNetworking,
		DaemonJSON:           cfg.DaemonJSON,
		DockerSubnet:         cfg.DockerSubnet,
		BindLocalhostOnly:    cfg.BindLocalhostOnly,
		EnableAmd64Emulation: cfg.EnableAmd64Emulation,
		PrivilegedPorts:      cfg.PrivilegedPorts,
	}
}
