package api

import (
	"net/http"
	"strings"
)

func (s *Server) handleVolumes(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		volumes, err := s.runtime.ListVolumes(r.Context())
		if err != nil {
			if writeRuntimeError(w, err) {
				return
			}

			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}

		writeJSON(w, http.StatusOK, volumes)
	case http.MethodPost:
		var payload struct {
			Name string `json:"name"`
		}

		if err := jsonDecode(r, &payload); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		if err := s.runtime.CreateVolume(r.Context(), payload.Name); err != nil {
			if writeRuntimeError(w, err) {
				return
			}

			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	default:
		methodNotAllowed(w, r)
	}
}

func (s *Server) handleVolumeAction(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodDelete {
		methodNotAllowed(w, r)
		return
	}

	name := strings.TrimPrefix(r.URL.Path, "/v1/volumes/")
	if name == "" {
		writeError(w, http.StatusNotFound, "volume not found")
		return
	}

	if err := s.runtime.RemoveVolume(r.Context(), name); err != nil {
		if writeRuntimeError(w, err) {
			return
		}

		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
