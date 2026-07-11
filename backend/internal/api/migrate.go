package api

import (
	"github.com/enegalan/calf/backend/internal/httpkit"
	"net/http"

)

// handleDockerDesktopMigration serves GET and POST /v1/migrate/docker-desktop for status and starting migration.
func (g *Gateway) handleDockerDesktopMigration(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		httpkit.WriteJSON(w, http.StatusOK, g.backend.MigrationStatus())

	case http.MethodPost:
		status, started := g.backend.TryStartMigration()
		if !started {
			httpkit.WriteError(w, http.StatusConflict, "migration already running")
			return
		}

		go g.backend.RunDockerDesktopMigration()
		httpkit.WriteJSON(w, http.StatusAccepted, status)

	default:
		httpkit.MethodNotAllowed(w, r)
	}
}
