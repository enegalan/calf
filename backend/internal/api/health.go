package api

import (
	"net/http"

	"github.com/enegalan/calf/backend/internal/httpkit"
)

type healthResponse struct {
	Status string `json:"status"`
}

// handleHealth serves GET /v1/health with a simple ok status.
func (g *Gateway) handleHealth(w http.ResponseWriter, r *http.Request) {
	httpkit.WriteJSON(w, http.StatusOK, healthResponse{Status: "ok"})
}
