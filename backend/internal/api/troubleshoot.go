package api

import (
	"context"
	"net/http"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/utils"
)

// handleTroubleshootPurge serves POST /v1/troubleshoot/purge.
func (g *Gateway) handleTroubleshootPurge(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), constants.TroubleshootActionTimeout)
	defer cancel()

	if err := g.backend.PurgeData(ctx); err != nil {
		httpkit.WriteError(w, http.StatusInternalServerError, err.Error())
		return
	}
	utils.WriteOK(w)
}

// handleTroubleshootFactoryReset serves POST /v1/troubleshoot/factory-reset.
func (g *Gateway) handleTroubleshootFactoryReset(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), constants.TroubleshootActionTimeout)
	defer cancel()

	if err := g.backend.FactoryReset(ctx); err != nil {
		httpkit.WriteError(w, http.StatusInternalServerError, err.Error())
		return
	}
	utils.WriteOK(w)
}
