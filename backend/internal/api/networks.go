package api

import (
	"context"
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/utils"
)

func (s *Server) handleNetworks(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		ctx, cancel := context.WithTimeout(r.Context(), constants.DefaultActionTimeout)
		defer cancel()

		networks, err := s.runtime.ListNetworks(ctx)
		if err != nil {
			writeRuntimeOrFail(w, err)
			return
		}

		writeJSON(w, http.StatusOK, networks)
	default:
		methodNotAllowed(w, r)
	}
}

func (s *Server) handleNetworkAction(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	name := strings.TrimPrefix(r.URL.Path, "/v1/networks/")
	name = strings.Trim(name, "/")
	if name == "" {
		writeError(w, http.StatusNotFound, "network not found")
		return
	}

	switch r.Method {
	case http.MethodGet:
		ctx, cancel := context.WithTimeout(r.Context(), constants.DefaultActionTimeout)
		defer cancel()

		detail, err := s.runtime.InspectNetwork(ctx, name)
		if err != nil {
			writeRuntimeOrFail(w, err)
			return
		}

		writeJSON(w, http.StatusOK, detail)
	case http.MethodDelete:
		ctx, cancel := context.WithTimeout(r.Context(), constants.DefaultActionTimeout)
		defer cancel()

		if err := s.runtime.RemoveNetwork(ctx, name); err != nil {
			writeRuntimeOrFail(w, err)
			return
		}

		utils.WriteOK(w)
	default:
		methodNotAllowed(w, r)
	}
}
