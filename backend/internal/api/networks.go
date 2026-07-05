package api

import (
	"net/http"
	"strings"
)

func (s *Server) handleNetworks(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		networks, err := s.runtime.ListNetworks(r.Context())
		if err != nil {
			if writeRuntimeError(w, err) {
				return
			}

			writeError(w, http.StatusInternalServerError, err.Error())
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
		detail, err := s.runtime.InspectNetwork(r.Context(), name)
		if err != nil {
			if writeRuntimeError(w, err) {
				return
			}

			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}

		writeJSON(w, http.StatusOK, detail)
	case http.MethodDelete:
		if err := s.runtime.RemoveNetwork(r.Context(), name); err != nil {
			if writeRuntimeError(w, err) {
				return
			}

			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	default:
		methodNotAllowed(w, r)
	}
}
