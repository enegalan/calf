package api

import (
	"net/http"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/utils"
)

// handleBuildersList serves GET /v1/builders.
func (g *Gateway) handleBuildersList(w http.ResponseWriter, r *http.Request) {
	r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
	defer cancel()

	builders, err := g.backend.Runtime.ListBuilders(r.Context())
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}
	httpkit.WriteJSON(w, http.StatusOK, builders)
}

// handleBuilderAction routes /v1/builders/{name}/use and DELETE.
func (g *Gateway) handleBuilderAction() http.HandlerFunc {
	return httpkit.ServeRoutes("/v1/builders/", "builder not found", []httpkit.Route{
		{
			Segments: []string{"use"},
			Method:   http.MethodPost,
			Handler: func(w http.ResponseWriter, r *http.Request, parts []string) {
				r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
				defer cancel()
				if err := g.backend.Runtime.UseBuilder(r.Context(), parts[0]); err != nil {
					httpkit.WriteRuntimeOrFail(w, err)
					return
				}
				utils.WriteOK(w)
			},
		},
	}, map[string]httpkit.PartsHandler{
		http.MethodDelete: func(w http.ResponseWriter, r *http.Request, parts []string) {
			r, cancel := httpkit.WithTimeout(r, constants.DefaultActionTimeout)
			defer cancel()
			if err := g.backend.Runtime.RemoveBuilder(r.Context(), parts[0]); err != nil {
				httpkit.WriteRuntimeOrFail(w, err)
				return
			}
			utils.WriteOK(w)
		},
	})
}
