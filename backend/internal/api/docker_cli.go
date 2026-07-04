package api

import (
	"context"
	"os"
	"time"

	"github.com/enegalan/calf/backend/internal/dockercli"
	"github.com/enegalan/calf/backend/internal/runtime"
)

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

func (s *Server) ensureDockerContext(ctx context.Context) {
	if !s.cfg.DockerContextManaged {
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

	if err := dockercli.EnsureAndActivate(ctx, socket); err != nil {
		s.logger.Debug("docker context activation skipped", "error", err)
	}
}

func (s *Server) dockerCLIStatus() (dockercli.Status, error) {
	return dockercli.StatusFor(s.runtime.DockerSocket(), s.cfg.DockerContextManaged)
}

func (s *Server) activateDockerContext(ctx context.Context) error {
	socket := s.runtime.DockerSocket()
	if socket == "" {
		return nil
	}

	return dockercli.EnsureAndActivate(ctx, socket)
}
