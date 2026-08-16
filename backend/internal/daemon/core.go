package daemon

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
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
	statsHistory          *statsHistory
	DockerCLI             *dockercli.Manager
	lifecycleCtx          context.Context
	lifecycleCancel       context.CancelFunc
	runtimeStartMu        sync.Mutex
	runtimeStartInflight  *runtimeStartResult
	resourceSaver         *resourceSaver
	snapshot              resourceSnapshot
	dockerSocketProxy     *dockerSocketProxy
	historyArtifactSkip   sync.Map
}

// runtimeStartResult is the shared completion of one in-flight EnsureRuntimeRunning start.
type runtimeStartResult struct {
	done chan struct{}
	err  error
}

// ownerContextSetter is implemented by runtimes whose background work should follow daemon shutdown.
type ownerContextSetter interface {
	SetOwnerContext(ctx context.Context)
}

// New constructs a Core, starts the export scheduler, and loads persisted build history.
func New(cfg config.Config, logger *slog.Logger, rt runtime.Runtime) *Core {
	lifecycleCtx, lifecycleCancel := context.WithCancel(context.Background())
	if setter, ok := rt.(ownerContextSetter); ok {
		setter.SetOwnerContext(lifecycleCtx)
	}
	srv := &Core{
		Cfg:                   cfg,
		Logger:                logger,
		Runtime:               rt,
		StartTime:             time.Now(),
		migrateStatus:         migration.IdleStatus(),
		registryLoginSessions: &sync.Map{},
		logBroadcaster:        newLogBroadcaster(logger),
		statsHistory:          newStatsHistory(constants.StatsHistoryRetention),
		lifecycleCtx:          lifecycleCtx,
		lifecycleCancel:       lifecycleCancel,
	}
	srv.exportScheduler = newExportScheduler(srv, logger)
	srv.exportScheduler.Start()
	srv.resourceSaver = newResourceSaver(srv)
	srv.resourceSaver.Start()
	srv.DockerCLI = dockercli.NewManager(logger, srv.dockerContextManaged, rt)
	srv.startDockerSocketProxy()
	srv.loadBuilds()
	return srv
}

// startDockerSocketProxy binds the public Docker CLI socket when the runtime uses a separate engine socket.
func (s *Core) startDockerSocketProxy() {
	public := s.Runtime.DockerSocket()
	engine := resolveEngineDockerSocket(s.Runtime)
	if public == "" || engine == "" || public == engine {
		return
	}
	var gater engineConnGater
	if g, ok := s.Runtime.(engineConnGater); ok {
		gater = g
	}
	proxy := newDockerSocketProxy(s.Logger, public, engine, s.lifecycleCtx, s.EnsureRuntimeRunning, gater)
	if err := proxy.Start(); err != nil {
		s.Logger.Warn("docker socket proxy failed to start", "error", err)
		return
	}
	s.dockerSocketProxy = proxy
}

// Lifecycle returns the daemon context canceled during Shutdown.
func (s *Core) Lifecycle() context.Context {
	return s.lifecycleCtx
}

// Shutdown stops background workers owned by the daemon.
func (s *Core) Shutdown(ctx context.Context) error {
	if s.lifecycleCancel != nil {
		s.lifecycleCancel()
	}
	s.stopRegistryLoginSessions()
	if s.exportScheduler != nil {
		s.exportScheduler.Stop()
	}
	if s.resourceSaver != nil {
		s.resourceSaver.Stop()
	}
	if s.dockerSocketProxy != nil {
		s.dockerSocketProxy.Stop()
		s.dockerSocketProxy = nil
	}
	return nil
}

// ForceStopRuntime stops the engine and restores wake-on-connect proxy mode.
func (s *Core) ForceStopRuntime(ctx context.Context) error {
	err := s.Runtime.ForceStop(ctx)
	if s.dockerSocketProxy != nil {
		if proxyErr := s.dockerSocketProxy.UseProxy(); proxyErr != nil {
			s.Logger.Warn("docker socket proxy restore after force-stop failed", "error", proxyErr)
		}
	}
	return err
}

// stopRegistryLoginSessions cancels in-flight Docker Hub device-login flows during shutdown.
func (s *Core) stopRegistryLoginSessions() {
	s.loginSessions().Range(func(key, value any) bool {
		session := value.(*registryLoginSession)
		if session.cancel != nil {
			session.cancel()
		}
		s.loginSessions().Delete(key)
		return true
	})
}

func (s *Core) dockerContextManaged() bool {
	s.CfgMu.RLock()
	defer s.CfgMu.RUnlock()
	return s.Cfg.DockerContextManaged
}
