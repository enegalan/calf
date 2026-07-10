package api

import (
	"net/http"

	"github.com/enegalan/calf/backend/internal/utils"
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
			writeRuntimeOrFail(w, err)
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

		if !s.ensureRuntimeOrFail(w, r.Context()) {
			return
		}

		if err := s.runtime.RegistryLogin(r.Context(), payload.Server, payload.Username, payload.Password); err != nil {
			writeRuntimeOrFail(w, err)
			return
		}

		utils.WriteOK(w)
	case http.MethodDelete:
		server := r.URL.Query().Get("server")

		if !s.ensureRuntimeOrFail(w, r.Context()) {
			return
		}

		if err := s.runtime.RegistryLogout(r.Context(), server); err != nil {
			writeRuntimeOrFail(w, err)
			return
		}

		utils.WriteOK(w)
	default:
		methodNotAllowed(w, r)
	}
}
