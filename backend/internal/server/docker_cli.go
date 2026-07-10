package api

import (
	"context"
	"os"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/dockercli"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// StartDockerContextManager periodically ensures the Calf Docker CLI context is active while managed mode is on.
func (s *Server) StartDockerContextManager(ctx context.Context) {
	interval := 5 * time.Second
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	s.ensureDockerContext(ctx)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.ensureDockerContext(ctx)
		}
	}
}

// ensureDockerContext activates the Calf docker context when managed mode is enabled and the runtime is ready.
func (s *Server) ensureDockerContext(ctx context.Context) {
	s.cfgMu.RLock()
	managed := s.cfg.DockerContextManaged
	s.cfgMu.RUnlock()

	if !managed {
		return
	}

	socket := s.runtime.DockerSocket()
	if socket == "" {
		return
	}

	if _, err := os.Stat(socket); err != nil {
		return
	}

	status, err := s.runtime.Status(ctx)
	if err != nil || status.State != runtime.StateRunning {
		return
	}

	activateCtx, cancel := context.WithTimeout(ctx, constants.DefaultActionTimeout)
	defer cancel()

	if err := dockercli.EnsureAndActivate(activateCtx, socket); err != nil {
		s.logger.Debug("docker context activation skipped", "error", err)
	}
}

// dockerCLIStatus returns whether the docker CLI is available and using the Calf context.
func (s *Server) dockerCLIStatus() (dockercli.Status, error) {
	s.cfgMu.RLock()
	managed := s.cfg.DockerContextManaged
	s.cfgMu.RUnlock()

	return dockercli.StatusFor(s.runtime.DockerSocket(), managed)
}

// activateDockerContext creates or switches to the Calf docker CLI context for the runtime socket.
func (s *Server) activateDockerContext(ctx context.Context) error {
	socket := s.runtime.DockerSocket()
	if socket == "" {
		return nil
	}

	return dockercli.EnsureAndActivate(ctx, socket)
}
