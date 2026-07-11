package daemon

import (
	"context"
	"fmt"
	"strings"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/limavm"
	"github.com/enegalan/calf/backend/internal/migration"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// MigrationStatus returns the current Docker Desktop migration status snapshot.
func (s *Core) MigrationStatus() migration.Status {
	s.migrateMu.RLock()
	defer s.migrateMu.RUnlock()
	return s.migrateStatus
}

// TryStartMigration marks migration as running or reports a conflict when one is already active.
func (s *Core) TryStartMigration() (migration.Status, bool) {
	s.migrateMu.Lock()
	defer s.migrateMu.Unlock()

	if s.migrateRunning {
		return s.migrateStatus, false
	}

	s.migrateRunning = true
	s.migrateStatus = migration.Status{
		Phase:    migration.Phase(constants.MigrationPhaseRunning),
		Step:     "starting",
		Progress: 0,
		Message:  "Starting migration",
	}
	return s.migrateStatus, true
}

// RunDockerDesktopMigration executes the Docker Desktop migration workflow in a background goroutine.
func (s *Core) RunDockerDesktopMigration() {
	ctx, cancel := context.WithTimeout(context.Background(), constants.BuildJobTimeout)
	defer cancel()

	defer func() {
		s.migrateMu.Lock()
		s.migrateRunning = false
		s.migrateMu.Unlock()
	}()

	status := migration.RunFromDockerDesktop(ctx, migration.Options{
		CalfSocket: s.Runtime.DockerSocket(),
		VMName:     s.Cfg.VMName,
		RunNerdctl: s.runNerdctl,
		Logger:     s.Logger,
		OnStatus: func(update migration.Status) {
			s.migrateMu.Lock()
			s.migrateStatus = update
			s.migrateMu.Unlock()
		},
		SaveConfig: func(cfg config.Config) error {
			s.CfgMu.Lock()
			defer s.CfgMu.Unlock()

			s.Cfg.CPUs = cfg.CPUs
			s.Cfg.MemoryGB = cfg.MemoryGB
			s.Cfg.MemorySwapGB = cfg.MemorySwapGB
			return config.Save(s.Cfg)
		},
		AddBuild: s.AddMigratedBuild,
	})

	s.migrateMu.Lock()
	s.migrateStatus = status
	s.migrateMu.Unlock()

	s.CfgMu.RLock()
	managed := s.Cfg.DockerContextManaged
	s.CfgMu.RUnlock()

	if status.Phase == migration.Phase(constants.MigrationPhaseCompleted) && managed {
		activateCtx, cancel := context.WithTimeout(ctx, constants.DefaultActionTimeout)
		defer cancel()
		if err := s.DockerCLI.Activate(activateCtx); err != nil {
			s.Logger.Warn("failed to activate docker context after migration", "error", err)
		}
	}
}

// runNerdctl runs nerdctl inside the Lima VM via limactl shell for migration operations.
func (s *Core) runNerdctl(ctx context.Context, args ...string) error {
	vmName := s.Cfg.VMName
	if vmName == "" {
		vmName = constants.DefaultVMName
	}

	shellArgs := runtime.NerdctlVMArgs(args...)
	output, err := limavm.Shell(ctx, vmName, shellArgs...)
	if err != nil {
		return fmt.Errorf("nerdctl %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}

	return nil
}
