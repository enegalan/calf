package api

import (
	"net/http"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/utils"
)

// handleRegistryStatus serves GET /v1/registry.
func (g *Gateway) handleRegistryStatus(w http.ResponseWriter, r *http.Request) {
	r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
	defer cancel()

	status, err := g.backend.Runtime.RegistryStatus(r.Context())
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, status)
}

// handleRegistryCredentials serves POST /v1/registry.
func (g *Gateway) handleRegistryCredentials(w http.ResponseWriter, r *http.Request) {
	r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
	defer cancel()

	var payload struct {
		Server   string `json:"server"`
		Username string `json:"username"`
		Password string `json:"password"`
	}

	if !httpkit.JSONDecodeOrFail(w, r, &payload) {
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
}

// handleRegistryLogout serves DELETE /v1/registry.
func (g *Gateway) handleRegistryLogout(w http.ResponseWriter, r *http.Request) {
	r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
	defer cancel()

	server := r.URL.Query().Get("server")

	if !httpkit.EnsureRuntimeOrFail(w, r.Context(), g.backend) {
		return
	}

	if err := g.backend.Runtime.RegistryLogout(r.Context(), server); err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	utils.WriteOK(w)
}
