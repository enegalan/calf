package api

import (
	"context"
	"errors"
	"net/http"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/runtime"
)

// handlePrunePreview serves GET /v1/system/prune/preview with reclaimable unused data.
func (g *Gateway) handlePrunePreview(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), constants.DefaultActionTimeout)
	defer cancel()

	preview, err := g.backend.Runtime.PrunePreview(ctx)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, preview)
}

// handlePrune serves POST /v1/system/prune for selected unused-resource categories.
func (g *Gateway) handlePrune(w http.ResponseWriter, r *http.Request) {
	var opts runtime.PruneOptions
	if err := httpkit.JSONDecode(r, &opts); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, "invalid json body")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), constants.TroubleshootActionTimeout)
	defer cancel()

	result, err := g.backend.Runtime.Prune(ctx, opts)
	if err != nil {
		if errors.Is(err, runtime.ErrPruneCategoryRequired) {
			httpkit.WriteError(w, http.StatusBadRequest, err.Error())
			return
		}
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, result)
}

// handleSystemDf serves GET /v1/system/df with Images/Containers/Volumes/Build Cache usage.
func (g *Gateway) handleSystemDf(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), constants.DefaultActionTimeout)
	defer cancel()

	usage, err := g.backend.Runtime.SystemDiskUsage(ctx)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, usage)
}
