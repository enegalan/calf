package api

import (
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/httpkit"
)

type registryDeviceLoginStartResponse struct {
	SessionID       string `json:"session_id"`
	UserCode        string `json:"user_code"`
	VerificationURL string `json:"verification_url"`
	ExpiresIn       int    `json:"expires_in"`
}

type registryDeviceLoginStatusResponse struct {
	Status   string `json:"status"`
	Username string `json:"username,omitempty"`
	Error    string `json:"error,omitempty"`
}

// handleRegistryLogin routes /v1/registry/login for starting and polling Docker Hub device-flow login.
func (g *Gateway) handleRegistryLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/v1/registry/login")
	path = strings.Trim(path, "/")

	if path == "" {
		if r.Method != http.MethodPost {
			httpkit.MethodNotAllowed(w, r)
			return
		}
		g.handleRegistryDeviceLoginStart(w, r)
		return
	}

	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	g.handleRegistryDeviceLoginStatus(w, r, path)
}

// handleRegistryDeviceLoginStart serves POST /v1/registry/login.
func (g *Gateway) handleRegistryDeviceLoginStart(w http.ResponseWriter, r *http.Request) {
	start, err := g.backend.StartRegistryDeviceLogin(r.Context())
	if err != nil {
		httpkit.WriteError(w, http.StatusBadGateway, err.Error())
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, registryDeviceLoginStartResponse{
		SessionID:       start.SessionID,
		UserCode:        start.UserCode,
		VerificationURL: start.VerificationURL,
		ExpiresIn:       start.ExpiresIn,
	})
}

// handleRegistryDeviceLoginStatus serves GET /v1/registry/login/{sessionID}.
func (g *Gateway) handleRegistryDeviceLoginStatus(w http.ResponseWriter, r *http.Request, sessionID string) {
	status, ok := g.backend.RegistryDeviceLoginStatus(sessionID)
	if !ok {
		httpkit.WriteError(w, http.StatusNotFound, "login session not found")
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, registryDeviceLoginStatusResponse{
		Status:   status.Status,
		Username: status.Username,
		Error:    status.Error,
	})
}
