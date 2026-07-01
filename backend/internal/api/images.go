package api

import (
	"net/http"
	"strings"
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
			writeError(w, http.StatusInternalServerError, err.Error())
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
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	default:
		methodNotAllowed(w, r)
	}
}

func (s *Server) handleImageAction(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodDelete {
		methodNotAllowed(w, r)
		return
	}

	ref := strings.TrimPrefix(r.URL.Path, "/v1/images/")
	if ref == "" {
		writeError(w, http.StatusNotFound, "image not found")
		return
	}

	if err := s.runtime.RemoveImage(r.Context(), ref); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
