package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/migration"
	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/gorilla/websocket"
)

type Server struct {
	cfg        config.Config
	cfgMu      sync.RWMutex
	logger     *slog.Logger
	runtime    runtime.Runtime
	startTime  time.Time
	httpServer *http.Server
	buildsMu       sync.RWMutex
	builds         []runtime.Build
	buildSeq       int
	migrateMu      sync.RWMutex
	migrateStatus  migration.Status
	migrateRunning bool
	registrySessions *sync.Map
	logBroadcaster   *logBroadcaster
	exportScheduler  *exportScheduler
}

var logsUpgrader = websocket.Upgrader{
	CheckOrigin: func(_ *http.Request) bool {
		return true
	},
}

func New(cfg config.Config, logger *slog.Logger, rt runtime.Runtime) *Server {
	server := &Server{
		cfg:              cfg,
		logger:           logger,
		runtime:          rt,
		startTime:        time.Now(),
		migrateStatus:    migration.IdleStatus(),
		logBroadcaster:   newLogBroadcaster(),
	}
	server.exportScheduler = newExportScheduler(server, logger)
	server.exportScheduler.Start()
	server.loadBuilds()
	return server
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/health", s.handleHealth)
	mux.HandleFunc("/v1/status", s.handleStatus)
	mux.HandleFunc("/v1/containers", s.handleContainers)
	mux.HandleFunc("/v1/containers/", s.handleContainerAction)
	mux.HandleFunc("/v1/images", s.handleImages)
	mux.HandleFunc("/v1/images/", s.handleImageSubpath)
	mux.HandleFunc("/v1/volumes", s.handleVolumes)
	mux.HandleFunc("/v1/volumes/", s.handleVolumeAction)
	mux.HandleFunc("/v1/networks", s.handleNetworks)
	mux.HandleFunc("/v1/networks/", s.handleNetworkAction)
	mux.HandleFunc("/v1/builds", s.handleBuilds)
	mux.HandleFunc("/v1/builds/", s.handleBuildAction)
	mux.HandleFunc("/v1/registry", s.handleRegistry)
	mux.HandleFunc("/v1/registry/login", s.handleRegistryLogin)
	mux.HandleFunc("/v1/registry/login/", s.handleRegistryLogin)
	mux.HandleFunc("/v1/config", s.handleConfig)
	mux.HandleFunc("/v1/migrate/docker-desktop", s.handleDockerDesktopMigration)

	return withMiddleware(s.logger, mux)
}

func (s *Server) Run() error {
	s.httpServer = &http.Server{
		Addr:              s.cfg.ListenAddr,
		Handler:           s.Handler(),
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      0,
		IdleTimeout:       60 * time.Second,
		ReadHeaderTimeout: 5 * time.Second,
	}

	s.logger.Info("listening", "addr", s.cfg.ListenAddr)
	return s.httpServer.ListenAndServe()
}

func (s *Server) Shutdown(ctx context.Context) error {
	if s.exportScheduler != nil {
		s.exportScheduler.Stop()
	}

	if s.httpServer == nil {
		return nil
	}

	return s.httpServer.Shutdown(ctx)
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func methodNotAllowed(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	writeError(w, http.StatusMethodNotAllowed, "method not allowed")
}
