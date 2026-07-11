package api

import (
	"github.com/enegalan/calf/backend/internal/httpkit"
	"context"
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/utils"
)

// handleNetworks serves GET /v1/networks with the list of Docker networks.
func (g *Gateway) handleNetworks(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		ctx, cancel := context.WithTimeout(r.Context(), constants.DefaultActionTimeout)
		defer cancel()

		networks, err := g.backend.Runtime.ListNetworks(ctx)
		if err != nil {
			httpkit.WriteRuntimeOrFail(w, err)
			return
		}

		httpkit.WriteJSON(w, http.StatusOK, networks)
	default:
		httpkit.MethodNotAllowed(w, r)
	}
}

// handleNetworkAction serves GET and DELETE /v1/networks/{name} for inspect and removal.
func (g *Gateway) handleNetworkAction(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	name := strings.TrimPrefix(r.URL.Path, "/v1/networks/")
	name = strings.Trim(name, "/")
	if name == "" {
		httpkit.WriteError(w, http.StatusNotFound, "network not found")
		return
	}

	switch r.Method {
	case http.MethodGet:
		ctx, cancel := context.WithTimeout(r.Context(), constants.DefaultActionTimeout)
		defer cancel()

		detail, err := g.backend.Runtime.InspectNetwork(ctx, name)
		if err != nil {
			httpkit.WriteRuntimeOrFail(w, err)
			return
		}

		httpkit.WriteJSON(w, http.StatusOK, detail)
	case http.MethodDelete:
		ctx, cancel := context.WithTimeout(r.Context(), constants.DefaultActionTimeout)
		defer cancel()

		if err := g.backend.Runtime.RemoveNetwork(ctx, name); err != nil {
			httpkit.WriteRuntimeOrFail(w, err)
			return
		}

		utils.WriteOK(w)
	default:
		httpkit.MethodNotAllowed(w, r)
	}
}
