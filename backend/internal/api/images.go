package api

import (
	"github.com/enegalan/calf/backend/internal/httpkit"
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/utils"
)

// handleImages serves GET /v1/images and POST /v1/images for listing and pulling images.
func (g *Gateway) handleImages(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		images, err := g.backend.Runtime.ListImages(r.Context())
		if err != nil {
			httpkit.WriteRuntimeOrFail(w, err)
			return
		}

		httpkit.WriteJSON(w, http.StatusOK, images)
	case http.MethodPost:
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
	default:
		httpkit.MethodNotAllowed(w, r)
	}
}

// handleImageSubpath routes /v1/images/ subpaths to layers, run, push, or delete handlers.
func (g *Gateway) handleImageSubpath(w http.ResponseWriter, r *http.Request) {
	subpath := strings.TrimPrefix(r.URL.Path, "/v1/images/")
	subpath = strings.Trim(subpath, "/")

	switch subpath {
	case "layers":
		g.handleImageLayers(w, r)
	case "run":
		g.handleImageRun(w, r)
	case "push":
		g.handleImagePush(w, r)
	case "":
		httpkit.WriteError(w, http.StatusNotFound, "image not found")
	default:
		g.handleImageDelete(w, r, subpath)
	}
}

// handleImageDelete serves DELETE /v1/images/{ref} to remove an image.
func (g *Gateway) handleImageDelete(w http.ResponseWriter, r *http.Request, ref string) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodDelete {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	if err := g.backend.Runtime.RemoveImage(r.Context(), ref); err != nil {
		httpkit.WriteRuntimeOrFail(w, err)
		return
	}

	utils.WriteOK(w)
}

// handleImageLayers serves GET /v1/images/layers with build history for a reference query param.
func (g *Gateway) handleImageLayers(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		httpkit.MethodNotAllowed(w, r)
		return
	}

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
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodPost {
		httpkit.MethodNotAllowed(w, r)
		return
	}

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
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodPost {
		httpkit.MethodNotAllowed(w, r)
		return
	}

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
