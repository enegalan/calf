package api

import (
	"net/http"

	"github.com/enegalan/calf/backend/internal/httpkit"
)

// handleDockerDesktopMigrationStatus serves GET /v1/migrate/docker-desktop.
func (g *Gateway) handleDockerDesktopMigrationStatus(w http.ResponseWriter, r *http.Request) {
	httpkit.WriteJSON(w, http.StatusOK, g.backend.MigrationStatus())
}

// handleDockerDesktopMigrationStart serves POST /v1/migrate/docker-desktop.
func (g *Gateway) handleDockerDesktopMigrationStart(w http.ResponseWriter, r *http.Request) {
	status, started := g.backend.TryStartMigration()
	if !started {
		httpkit.WriteError(w, http.StatusConflict, "migration already running")
		return
	}

	go g.backend.RunDockerDesktopMigration()
	httpkit.WriteJSON(w, http.StatusAccepted, status)
}
