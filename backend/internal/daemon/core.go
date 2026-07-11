package daemon

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/dockercli"
	"github.com/enegalan/calf/backend/internal/migration"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// Core holds daemon state, background workers, and services used by the HTTP API.
type Core struct {
	Cfg                   config.Config
	CfgMu                 sync.RWMutex
	Logger                *slog.Logger
	Runtime               runtime.Runtime
	StartTime             time.Time
	BuildsMu              sync.RWMutex
	Builds                []runtime.Build
	BuildSeq              int
	migrateMu             sync.RWMutex
	migrateStatus         migration.Status
	migrateRunning        bool
	registryLoginSessions *sync.Map
	logBroadcaster        *logBroadcaster
	exportScheduler       *exportScheduler
	DockerCLI             *dockercli.Manager
}

// New constructs a Core, starts the export scheduler, and loads persisted build history.
func New(cfg config.Config, logger *slog.Logger, rt runtime.Runtime) *Core {
	srv := &Core{
		Cfg:            cfg,
		Logger:         logger,
		Runtime:        rt,
		StartTime:      time.Now(),
		migrateStatus:  migration.IdleStatus(),
		logBroadcaster: newLogBroadcaster(),
	}
	srv.exportScheduler = newExportScheduler(srv, logger)
	srv.exportScheduler.Start()
	srv.DockerCLI = dockercli.NewManager(logger, srv.dockerContextManaged, rt)
	srv.loadBuilds()
	return srv
}

// Shutdown stops background workers owned by the daemon.
func (s *Core) Shutdown(ctx context.Context) error {
	if s.exportScheduler != nil {
		s.exportScheduler.Stop()
	}
	return nil
}

func (s *Core) dockerContextManaged() bool {
	s.CfgMu.RLock()
	defer s.CfgMu.RUnlock()
	return s.Cfg.DockerContextManaged
}
