package api

import (
	"net/http"

	"github.com/enegalan/calf/backend/internal/httpkit"
)

// registryDeviceLoginStartResponse represents the JSON payload for POST /v1/registry/login.
type registryDeviceLoginStartResponse struct {
	SessionID       string `json:"session_id"`
	UserCode        string `json:"user_code"`
	VerificationURL string `json:"verification_url"`
	ExpiresIn       int    `json:"expires_in"`
}

// registryDeviceLoginStatusResponse represents the JSON payload for GET /v1/registry/login/{sessionID}.
type registryDeviceLoginStatusResponse struct {
	Status   string `json:"status"`
	Username string `json:"username,omitempty"`
	Error    string `json:"error,omitempty"`
}

// handleRegistryLogin routes /v1/registry/login for starting and polling Docker Hub device-flow login.
func (g *Gateway) handleRegistryLogin() http.HandlerFunc {
	return httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
		http.MethodPost: func(w http.ResponseWriter, r *http.Request) {
			if httpkit.PathParts(r, "/v1/registry/login/") != nil {
				httpkit.MethodNotAllowed(w, r)
				return
			}

			g.handleRegistryDeviceLoginStart(w, r)
		},
		http.MethodGet: func(w http.ResponseWriter, r *http.Request) {
			parts := httpkit.PathParts(r, "/v1/registry/login/")
			if len(parts) != 1 {
				httpkit.MethodNotAllowed(w, r)
				return
			}

			g.handleRegistryDeviceLoginStatus(w, r, parts[0])
		},
	})
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
