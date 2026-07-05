package api

import (
	"context"
	"net/http"
	"strings"
	"time"
)

const networkActionTimeout = 30 * time.Second

func (s *Server) writeRuntimeOrInternalError(w http.ResponseWriter, err error) bool {
	if writeRuntimeError(w, err) {
		return true
	}

	writeError(w, http.StatusInternalServerError, err.Error())
	return false
}

func (s *Server) handleNetworks(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		ctx, cancel := context.WithTimeout(r.Context(), networkActionTimeout)
		defer cancel()

		networks, err := s.runtime.ListNetworks(ctx)
		if err != nil {
			s.writeRuntimeOrInternalError(w, err)
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
		ctx, cancel := context.WithTimeout(r.Context(), networkActionTimeout)
		defer cancel()

		detail, err := s.runtime.InspectNetwork(ctx, name)
		if err != nil {
			s.writeRuntimeOrInternalError(w, err)
			return
		}

		writeJSON(w, http.StatusOK, detail)
	case http.MethodDelete:
		ctx, cancel := context.WithTimeout(r.Context(), networkActionTimeout)
		defer cancel()

		if err := s.runtime.RemoveNetwork(ctx, name); err != nil {
			s.writeRuntimeOrInternalError(w, err)
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	default:
		methodNotAllowed(w, r)
	}
}
