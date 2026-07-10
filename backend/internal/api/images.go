package api

import (
	"net/http"
	"strings"

	"github.com/enegalan/calf/backend/internal/utils"
)

func (s *Server) handleImages(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		images, err := s.runtime.ListImages(r.Context())
		if err != nil {
			writeRuntimeOrFail(w, err)
			return
		}

		writeJSON(w, http.StatusOK, images)
	case http.MethodPost:
		var payload struct {
			Reference string `json:"reference"`
		}

		if err := jsonDecode(r, &payload); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		if payload.Reference == "" {
			writeError(w, http.StatusBadRequest, "reference is required")
			return
		}

		if err := s.runtime.PullImage(r.Context(), payload.Reference); err != nil {
			writeRuntimeOrFail(w, err)
			return
		}

		utils.WriteOK(w)
	default:
		methodNotAllowed(w, r)
	}
}

func (s *Server) handleImageSubpath(w http.ResponseWriter, r *http.Request) {
	subpath := strings.TrimPrefix(r.URL.Path, "/v1/images/")
	subpath = strings.Trim(subpath, "/")

	switch subpath {
	case "layers":
		s.handleImageLayers(w, r)
	case "run":
		s.handleImageRun(w, r)
	case "push":
		s.handleImagePush(w, r)
	case "":
		writeError(w, http.StatusNotFound, "image not found")
	default:
		s.handleImageDelete(w, r, subpath)
	}
}

func (s *Server) handleImageDelete(w http.ResponseWriter, r *http.Request, ref string) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodDelete {
		methodNotAllowed(w, r)
		return
	}

	if err := s.runtime.RemoveImage(r.Context(), ref); err != nil {
		writeRuntimeOrFail(w, err)
		return
	}

	utils.WriteOK(w)
}

func (s *Server) handleImageLayers(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	ref := r.URL.Query().Get("reference")
	if ref == "" {
		writeError(w, http.StatusBadRequest, "reference is required")
		return
	}

	layers, err := s.runtime.ImageHistory(r.Context(), ref)
	if err != nil {
		writeRuntimeOrFail(w, err)
		return
	}

	writeJSON(w, http.StatusOK, layers)
}

func (s *Server) handleImageRun(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodPost {
		methodNotAllowed(w, r)
		return
	}

	var payload struct {
		Reference string `json:"reference"`
	}

	if err := jsonDecode(r, &payload); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	if payload.Reference == "" {
		writeError(w, http.StatusBadRequest, "reference is required")
		return
	}

	containerID, err := s.runtime.RunImage(r.Context(), payload.Reference)
	if err != nil {
		writeRuntimeOrFail(w, err)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"status":       "ok",
		"container_id": containerID,
	})
}

func (s *Server) handleImagePush(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodPost {
		methodNotAllowed(w, r)
		return
	}

	var payload struct {
		Reference string `json:"reference"`
	}

	if err := jsonDecode(r, &payload); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	if payload.Reference == "" {
		writeError(w, http.StatusBadRequest, "reference is required")
		return
	}

	if err := s.runtime.PushImage(r.Context(), payload.Reference); err != nil {
		writeRuntimeOrFail(w, err)
		return
	}

	utils.WriteOK(w)
}
