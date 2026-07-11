package dockercli

import (
	"context"
	"log/slog"
	"os"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// RuntimePort is the runtime surface needed to manage the docker CLI context.
type RuntimePort interface {
	DockerSocket() string
	Status(ctx context.Context) (runtime.Status, error)
}

// Manager keeps the docker CLI pointed at the Calf socket while managed mode is enabled.
type Manager struct {
	logger  *slog.Logger
	managed func() bool
	runtime RuntimePort
}

// NewManager constructs a docker CLI context manager.
func NewManager(logger *slog.Logger, managed func() bool, rt RuntimePort) *Manager {
	return &Manager{
		logger:  logger,
		managed: managed,
		runtime: rt,
	}
}

// Start periodically ensures the Calf docker CLI context is active while managed mode is on.
func (m *Manager) Start(ctx context.Context) {
	ticker := time.NewTicker(constants.DockerContextManagerInterval)
	defer ticker.Stop()

	m.ensure(ctx)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.ensure(ctx)
		}
	}
}

// Status reports whether the docker CLI is available and how the calf context is configured.
func (m *Manager) Status() (Status, error) {
	return StatusFor(m.runtime.DockerSocket(), m.managed())
}

// Activate creates or switches to the Calf docker CLI context for the runtime socket.
func (m *Manager) Activate(ctx context.Context) error {
	socket := m.runtime.DockerSocket()
	if socket == "" {
		return nil
	}

	return EnsureAndActivate(ctx, socket)
}

func (m *Manager) ensure(ctx context.Context) {
	if !m.managed() {
		return
	}

	socket := m.runtime.DockerSocket()
	if socket == "" {
		return
	}

	if _, err := os.Stat(socket); err != nil {
		return
	}

	status, err := m.runtime.Status(ctx)
	if err != nil || status.State != runtime.StateRunning {
		return
	}

	activateCtx, cancel := context.WithTimeout(ctx, constants.DefaultActionTimeout)
	defer cancel()

	if err := EnsureAndActivate(activateCtx, socket); err != nil {
		m.logger.Debug("docker context activation skipped", "error", err)
	}
}
