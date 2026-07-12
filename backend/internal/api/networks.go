package api

import (
	"context"
	"net/http"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/utils"
)

// handleNetworksList serves GET /v1/networks with the list of Docker networks.
func (g *Gateway) handleNetworksList(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), constants.DefaultActionTimeout)
	defer cancel()

	networks, err := g.backend.Runtime.ListNetworks(ctx)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, networks)
}

// handleNetworkAction serves GET and DELETE /v1/networks/{name} for inspect and removal.
func (g *Gateway) handleNetworkAction() http.HandlerFunc {
	return httpkit.ServeRoutes("/v1/networks/", "network not found", nil, map[string]httpkit.PartsHandler{
		http.MethodGet: func(w http.ResponseWriter, r *http.Request, parts []string) {
			ctx, cancel := context.WithTimeout(r.Context(), constants.DefaultActionTimeout)
			defer cancel()

			detail, err := g.backend.Runtime.InspectNetwork(ctx, parts[0])
			if err != nil {
				httpkit.WriteRuntimeOrFail(w, err)
				return
			}

			httpkit.WriteJSON(w, http.StatusOK, detail)
		},
		http.MethodDelete: func(w http.ResponseWriter, r *http.Request, parts []string) {
			ctx, cancel := context.WithTimeout(r.Context(), constants.DefaultActionTimeout)
			defer cancel()

			if err := g.backend.Runtime.RemoveNetwork(ctx, parts[0]); err != nil {
				httpkit.WriteRuntimeOrFail(w, err)
				return
			}

			utils.WriteOK(w)
		},
	})
}
