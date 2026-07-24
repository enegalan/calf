package daemon

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
)

// PurgeData stops the engine and removes guest/runtime data while keeping settings.
func (s *Core) PurgeData(ctx context.Context) error {
	if err := s.stopRuntimeForTroubleshoot(ctx); err != nil {
		return err
	}

	cfgDir, err := config.ConfigDir()
	if err != nil {
		return fmt.Errorf("resolve config dir: %w", err)
	}

	guestDir := filepath.Join(cfgDir, "guest")
	if err := removePathIfExists(guestDir); err != nil {
		return fmt.Errorf("remove guest data: %w", err)
	}

	buildsPath, buildsErr := config.BuildsFilePath()
	if buildsErr != nil {
		return fmt.Errorf("resolve builds path: %w", buildsErr)
	}
	if err := removePathIfExists(buildsPath); err != nil {
		return fmt.Errorf("remove builds history: %w", err)
	}

	s.BuildsMu.Lock()
	s.Builds = nil
	s.BuildSeq = 0
	s.BuildsMu.Unlock()

	s.ClearResourceSaver()
	s.Logger.Info("purged engine data", "guest_dir", guestDir)
	return nil
}

// FactoryReset stops the engine, wipes Calf config data, and restores defaults.
func (s *Core) FactoryReset(ctx context.Context) error {
	if err := s.stopRuntimeForTroubleshoot(ctx); err != nil {
		return err
	}

	cfgDir, err := config.ConfigDir()
	if err != nil {
		return fmt.Errorf("resolve config dir: %w", err)
	}

	entries, readErr := os.ReadDir(cfgDir)
	if readErr != nil && !os.IsNotExist(readErr) {
		return fmt.Errorf("read config dir: %w", readErr)
	}
	for _, entry := range entries {
		path := filepath.Join(cfgDir, entry.Name())
		if err := os.RemoveAll(path); err != nil {
			return fmt.Errorf("remove %s: %w", path, err)
		}
	}

	defaults := config.Default()
	if err := config.Save(defaults); err != nil {
		return fmt.Errorf("write default config: %w", err)
	}

	s.CfgMu.Lock()
	s.Cfg = defaults
	s.CfgMu.Unlock()

	s.BuildsMu.Lock()
	s.Builds = nil
	s.BuildSeq = 0
	s.BuildsMu.Unlock()

	s.ClearResourceSaver()
	s.Logger.Info("factory reset complete", "config_dir", cfgDir)
	return nil
}

// stopRuntimeForTroubleshoot force-stops the runtime before destructive cleanup.
func (s *Core) stopRuntimeForTroubleshoot(ctx context.Context) error {
	stopCtx, cancel := context.WithTimeout(ctx, constants.DefaultActionTimeout)
	defer cancel()
	if err := s.Runtime.ForceStop(stopCtx); err != nil {
		return fmt.Errorf("stop runtime: %w", err)
	}
	s.ClearResourceSaver()
	// Brief pause so file locks on guest disk can release before deletion.
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(500 * time.Millisecond):
	}
	return nil
}

// removePathIfExists deletes path when present.
func removePathIfExists(path string) error {
	if path == "" {
		return nil
	}
	if err := os.RemoveAll(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
