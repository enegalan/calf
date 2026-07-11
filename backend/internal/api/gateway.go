package api

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/daemon"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/middleware"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// Gateway exposes the Calf REST and WebSocket API over HTTP.
type Gateway struct {
	cfg         config.Config
	logger      *slog.Logger
	backend     *daemon.Core
	httpServer  *http.Server
	middlewares []middleware.Middleware
}

// New constructs the HTTP gateway backed by a new daemon Core instance.
func New(cfg config.Config, logger *slog.Logger, rt runtime.Runtime) *Gateway {
	return NewGateway(cfg, logger, daemon.New(cfg, logger, rt))
}

// NewGateway wires an existing daemon Core to the HTTP API.
func NewGateway(cfg config.Config, logger *slog.Logger, backend *daemon.Core) *Gateway {
	return &Gateway{
		cfg:     cfg,
		logger:  logger,
		backend: backend,
	}
}

// Backend returns the daemon core that backs this gateway.
func (g *Gateway) Backend() *daemon.Core {
	return g.backend
}

// WithMiddleware registers HTTP middleware applied around all routes.
func (g *Gateway) WithMiddleware(middlewares ...middleware.Middleware) *Gateway {
	g.middlewares = append(g.middlewares, middlewares...)
	return g
}

// Handler returns the HTTP handler with all /v1 routes registered.
func (g *Gateway) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/health", httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
		http.MethodGet: g.handleHealth,
	}))
	mux.HandleFunc("/v1/status", httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
		http.MethodGet: g.handleStatus,
	}))
	mux.HandleFunc("/v1/containers", httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
		http.MethodGet: g.handleContainers,
	}))
	mux.HandleFunc("/v1/containers/", g.handleContainerAction())
	mux.HandleFunc("/v1/images", httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
		http.MethodGet:  g.handleImagesList,
		http.MethodPost: g.handleImagesPull,
	}))
	mux.HandleFunc("/v1/images/", g.handleImageSubpath())
	mux.HandleFunc("/v1/volumes", httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
		http.MethodGet:  g.handleVolumesList,
		http.MethodPost: g.handleVolumesCreate,
	}))
	mux.HandleFunc("/v1/volumes/", g.handleVolumeAction())
	mux.HandleFunc("/v1/networks", httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
		http.MethodGet: g.handleNetworksList,
	}))
	mux.HandleFunc("/v1/networks/", g.handleNetworkAction())
	mux.HandleFunc("/v1/builds", httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
		http.MethodGet:  g.handleBuildsList,
		http.MethodPost: g.handleBuildsCreate,
	}))
	mux.HandleFunc("/v1/builds/", g.handleBuildAction())
	mux.HandleFunc("/v1/registry", httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
		http.MethodGet:    g.handleRegistryStatus,
		http.MethodPost:   g.handleRegistryCredentials,
		http.MethodDelete: g.handleRegistryLogout,
	}))
	mux.HandleFunc("/v1/registry/login", g.handleRegistryLogin())
	mux.HandleFunc("/v1/registry/login/", g.handleRegistryLogin())
	mux.HandleFunc("/v1/config", httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
		http.MethodGet: g.handleConfigGet,
		http.MethodPut: g.handleConfigPut,
	}))
	mux.HandleFunc("/v1/migrate/docker-desktop", httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
		http.MethodGet:  g.handleDockerDesktopMigrationStatus,
		http.MethodPost: g.handleDockerDesktopMigrationStart,
	}))

	return middleware.Chain(mux, g.middlewares...)
}

// Run starts the HTTP server on the configured listen address.
func (g *Gateway) Run() error {
	g.httpServer = &http.Server{
		Addr:              g.cfg.ListenAddr,
		Handler:           g.Handler(),
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      0,
		IdleTimeout:       60 * time.Second,
		ReadHeaderTimeout: 5 * time.Second,
	}

	g.logger.Info("listening", "addr", g.cfg.ListenAddr)
	return g.httpServer.ListenAndServe()
}

// Shutdown gracefully stops the HTTP server and daemon background workers.
func (g *Gateway) Shutdown(ctx context.Context) error {
	if g.httpServer != nil {
		if err := g.httpServer.Shutdown(ctx); err != nil {
			return err
		}
	}

	return g.backend.Shutdown(ctx)
}
