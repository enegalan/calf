package api

import (
	"net/http"

	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/utils"
)

// handleImagesList serves GET /v1/images.
func (g *Gateway) handleImagesList(w http.ResponseWriter, r *http.Request) {
	images, err := g.backend.Runtime.ListImages(r.Context())
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, images)
}

// handleImagesPull serves POST /v1/images.
func (g *Gateway) handleImagesPull(w http.ResponseWriter, r *http.Request) {
	var payload struct {
		Reference string `json:"reference"`
	}

	if err := httpkit.JSONDecode(r, &payload); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	if payload.Reference == "" {
		httpkit.WriteError(w, http.StatusBadRequest, "reference is required")
		return
	}

	if err := g.backend.Runtime.PullImage(r.Context(), payload.Reference); err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	utils.WriteOK(w)
}

// handleImageSubpath routes /v1/images/ subpaths to layers, run, push, or delete handlers.
func (g *Gateway) handleImageSubpath() http.HandlerFunc {
	return httpkit.ServePrefix("/v1/images/", map[string]func(http.ResponseWriter, *http.Request){
		"layers": httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
			http.MethodGet: g.handleImageLayers,
		}),
		"run": httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
			http.MethodPost: g.handleImageRun,
		}),
		"push": httpkit.ServeMethods(map[string]func(http.ResponseWriter, *http.Request){
			http.MethodPost: g.handleImagePush,
		}),
	}, func(w http.ResponseWriter, r *http.Request, remaining string) {
		if remaining == "" {
			httpkit.WriteError(w, http.StatusNotFound, "image not found")
			return
		}

		httpkit.ServeMethod(http.MethodDelete, func(w http.ResponseWriter, r *http.Request) {
			g.handleImageDelete(w, r, remaining)
		})(w, r)
	})
}

// handleImageDelete serves DELETE /v1/images/{ref} to remove an image.
func (g *Gateway) handleImageDelete(w http.ResponseWriter, r *http.Request, ref string) {
	if err := g.backend.Runtime.RemoveImage(r.Context(), ref); err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	utils.WriteOK(w)
}

// handleImageLayers serves GET /v1/images/layers with build history for a reference query param.
func (g *Gateway) handleImageLayers(w http.ResponseWriter, r *http.Request) {
	ref := r.URL.Query().Get("reference")
	if ref == "" {
		httpkit.WriteError(w, http.StatusBadRequest, "reference is required")
		return
	}

	layers, err := g.backend.Runtime.ImageHistory(r.Context(), ref)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, layers)
}

// handleImageRun serves POST /v1/images/run to create and start a container from an image.
func (g *Gateway) handleImageRun(w http.ResponseWriter, r *http.Request) {
	var payload struct {
		Reference string `json:"reference"`
	}

	if err := httpkit.JSONDecode(r, &payload); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	if payload.Reference == "" {
		httpkit.WriteError(w, http.StatusBadRequest, "reference is required")
		return
	}

	containerID, err := g.backend.Runtime.RunImage(r.Context(), payload.Reference)
	if err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, map[string]string{
		"status":       "ok",
		"container_id": containerID,
	})
}

// handleImagePush serves POST /v1/images/push to push an image to a registry.
func (g *Gateway) handleImagePush(w http.ResponseWriter, r *http.Request) {
	var payload struct {
		Reference string `json:"reference"`
	}

	if err := httpkit.JSONDecode(r, &payload); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	if payload.Reference == "" {
		httpkit.WriteError(w, http.StatusBadRequest, "reference is required")
		return
	}

	if err := g.backend.Runtime.PushImage(r.Context(), payload.Reference); err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	utils.WriteOK(w)
}
