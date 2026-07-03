package api

import (
	"net/http"
)

func (s *Server) handleRegistry(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		status, err := s.runtime.RegistryStatus(r.Context())
		if err != nil {
			if writeRuntimeError(w, err) {
				return
			}

			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}

		writeJSON(w, http.StatusOK, status)
	case http.MethodPost:
		var payload struct {
			Server   string `json:"server"`
			Username string `json:"username"`
			Password string `json:"password"`
		}

		if err := jsonDecode(r, &payload); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		if err := s.ensureRuntimeRunning(r.Context()); err != nil {
			if writeRuntimeError(w, err) {
				return
			}

			writeError(w, http.StatusServiceUnavailable, err.Error())
			return
		}

		if err := s.runtime.RegistryLogin(r.Context(), payload.Server, payload.Username, payload.Password); err != nil {
			if writeRuntimeError(w, err) {
				return
			}

			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	case http.MethodDelete:
		server := r.URL.Query().Get("server")

		if err := s.ensureRuntimeRunning(r.Context()); err != nil {
			if writeRuntimeError(w, err) {
				return
			}

			writeError(w, http.StatusServiceUnavailable, err.Error())
			return
		}

		if err := s.runtime.RegistryLogout(r.Context(), server); err != nil {
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
