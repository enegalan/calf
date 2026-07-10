package api

import (
	"context"
	"fmt"
	"net/http"
	"os/exec"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/migration"
	"github.com/enegalan/calf/backend/internal/runtime"
)

func (s *Server) handleDockerDesktopMigration(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		s.migrateMu.RLock()
		status := s.migrateStatus
		s.migrateMu.RUnlock()
		writeJSON(w, http.StatusOK, status)

	case http.MethodPost:
		s.migrateMu.Lock()
		if s.migrateRunning {
			s.migrateMu.Unlock()
			writeError(w, http.StatusConflict, "migration already running")
			return
		}

		s.migrateRunning = true
		s.migrateStatus = migration.Status{
			Phase:    migration.PhaseRunning,
			Step:     "starting",
			Progress: 0,
			Message:  "Starting migration",
		}
		s.migrateMu.Unlock()

		go s.runDockerDesktopMigration()

		s.migrateMu.RLock()
		status := s.migrateStatus
		s.migrateMu.RUnlock()
		writeJSON(w, http.StatusAccepted, status)

	default:
		methodNotAllowed(w, r)
	}
}

func (s *Server) runDockerDesktopMigration() {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Hour)
	defer cancel()

	defer func() {
		s.migrateMu.Lock()
		s.migrateRunning = false
		s.migrateMu.Unlock()
	}()

	status := migration.RunFromDockerDesktop(ctx, migration.Options{
		CalfSocket: s.runtime.DockerSocket(),
		VMName:     s.cfg.VMName,
		RunNerdctl: s.runNerdctl,
		Logger:     s.logger,
		OnStatus: func(update migration.Status) {
			s.migrateMu.Lock()
			s.migrateStatus = update
			s.migrateMu.Unlock()
		},
		SaveConfig: func(cfg config.Config) error {
			s.cfgMu.Lock()
			defer s.cfgMu.Unlock()

			s.cfg.CPUs = cfg.CPUs
			s.cfg.MemoryGB = cfg.MemoryGB
			s.cfg.MemorySwapGB = cfg.MemorySwapGB
			return config.Save(s.cfg)
		},
		AddBuild: s.addMigratedBuild,
	})

	s.migrateMu.Lock()
	s.migrateStatus = status
	s.migrateMu.Unlock()

	s.cfgMu.RLock()
	managed := s.cfg.DockerContextManaged
	s.cfgMu.RUnlock()

	if status.Phase == migration.PhaseCompleted && managed {
		activateCtx, cancel := context.WithTimeout(ctx, constants.DefaultActionTimeout)
		defer cancel()
		if err := s.activateDockerContext(activateCtx); err != nil {
			s.logger.Warn("failed to activate docker context after migration", "error", err)
		}
	}
}

func (s *Server) runNerdctl(ctx context.Context, args ...string) error {
	vmName := s.cfg.VMName
	if vmName == "" {
		vmName = "calf"
	}

	shellArgs := append([]string{"shell", vmName, "--"}, runtime.NerdctlVMArgs(args...)...)
	command := exec.CommandContext(ctx, "limactl", shellArgs...)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("nerdctl %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}

	return nil
}
