package api

import (
	"net/http"

	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/utils"
)

// handleRegistry serves GET, POST, and DELETE /v1/registry for registry auth status, login, and logout.
func (g *Gateway) handleRegistry(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		status, err := g.backend.Runtime.RegistryStatus(r.Context())
		if err != nil {
			httpkit.WriteRuntimeOrFail(w, err)
			return
		}

		httpkit.WriteJSON(w, http.StatusOK, status)
	case http.MethodPost:
		var payload struct {
			Server   string `json:"server"`
			Username string `json:"username"`
			Password string `json:"password"`
		}

		if err := httpkit.JSONDecode(r, &payload); err != nil {
			httpkit.WriteError(w, http.StatusBadRequest, err.Error())
			return
		}

		if !httpkit.EnsureRuntimeOrFail(w, r.Context(), g.backend) {
			return
		}

		if err := g.backend.Runtime.RegistryLogin(r.Context(), payload.Server, payload.Username, payload.Password); err != nil {
			httpkit.WriteRuntimeOrFail(w, err)
			return
		}

		utils.WriteOK(w)
	case http.MethodDelete:
		server := r.URL.Query().Get("server")

		if !httpkit.EnsureRuntimeOrFail(w, r.Context(), g.backend) {
			return
		}

		if err := g.backend.Runtime.RegistryLogout(r.Context(), server); err != nil {
			httpkit.WriteRuntimeOrFail(w, err)
			return
		}

		utils.WriteOK(w)
	default:
		httpkit.MethodNotAllowed(w, r)
	}
}
