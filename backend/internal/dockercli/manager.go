package dockercli

import (
	"context"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
)

// RuntimePort is the runtime surface needed to manage the docker CLI context.
type RuntimePort interface {
	DockerSocket() string
}

// Manager keeps the docker CLI pointed at the calf socket while managed mode is enabled.
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

// Start periodically ensures the calf docker CLI context is active while managed mode is on.
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

// Activate creates or switches to the calf docker CLI context for the runtime socket.
func (m *Manager) Activate(ctx context.Context) error {
	m.repairPlugins()

	socket := m.runtime.DockerSocket()
	if socket == "" {
		return nil
	}

	return EnsureAndActivate(ctx, socket)
}

// ensure repairs CLI plugins and keeps the calf docker context active while managed mode is on.
func (m *Manager) ensure(ctx context.Context) {
	m.repairPlugins()

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

	// Keep the calf context selected whenever the public socket exists so Docker
	// CLI can wake Resource Saver via the daemon proxy without switching contexts.
	activateCtx, cancel := context.WithTimeout(ctx, constants.DefaultActionTimeout)
	defer cancel()

	if err := EnsureAndActivate(activateCtx, socket); err != nil {
		m.logger.Debug("docker context activation skipped", "error", err)
	}
}

// repairPlugins fixes broken or missing buildx/compose plugins left by Docker Desktop uninstalls.
func (m *Manager) repairPlugins() {
	status, repaired, err := EnsureCLIPlugins()
	if err != nil {
		m.logger.Warn("docker CLI plugin repair failed", "error", err)
		return
	}
	if len(repaired) > 0 {
		m.logger.Info("docker CLI plugins repaired", "plugins", strings.Join(repaired, ", "))
	}
	if !status.BuildxAvailable || !status.ComposeAvailable {
		m.logger.Debug("docker CLI plugins incomplete", "hint", status.Hint)
	}
}
