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

	path := strings.TrimPrefix(r.URL.Path, "/v1/volumes/")
	parts := strings.Split(path, "/")
	if len(parts) == 0 || parts[0] == "" {
		writeError(w, http.StatusNotFound, "volume not found")
		return
	}

	name := parts[0]

	if len(parts) == 2 {
		switch parts[1] {
		case "files":
			s.handleVolumeFiles(w, r, name)
			return
		case "containers":
			s.handleVolumeContainers(w, r, name)
			return
		case "clone":
			s.handleVolumeClone(w, r, name)
			return
		}
	}

	switch r.Method {
	case http.MethodGet:
		if len(parts) != 1 {
			methodNotAllowed(w, r)
			return
		}

		s.handleVolumeDetail(w, r, name)
	case http.MethodDelete:
		if len(parts) != 1 {
			methodNotAllowed(w, r)
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
	default:
		methodNotAllowed(w, r)
	}
}

func (s *Server) handleVolumeDetail(w http.ResponseWriter, r *http.Request, name string) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	detail, err := s.runtime.InspectVolume(r.Context(), name)
	if err != nil {
		if writeRuntimeError(w, err) {
			return
		}

		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, detail)
}

func (s *Server) handleVolumeFiles(w http.ResponseWriter, r *http.Request, name string) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	path := strings.TrimSpace(r.URL.Query().Get("path"))
	files, err := s.runtime.ListVolumeFiles(r.Context(), name, path)
	if err != nil {
		if writeRuntimeError(w, err) {
			return
		}

		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, files)
}

func (s *Server) handleVolumeContainers(w http.ResponseWriter, r *http.Request, name string) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	containers, err := s.runtime.VolumeContainers(r.Context(), name)
	if err != nil {
		if writeRuntimeError(w, err) {
			return
		}

		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, containers)
}

func (s *Server) handleVolumeClone(w http.ResponseWriter, r *http.Request, name string) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodPost {
		methodNotAllowed(w, r)
		return
	}

	var payload struct {
		Name string `json:"name"`
	}

	if err := jsonDecode(r, &payload); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	if strings.TrimSpace(payload.Name) == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}

	if err := s.runtime.CloneVolume(r.Context(), name, payload.Name); err != nil {
		if writeRuntimeError(w, err) {
			return
		}

		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"status": "ok",
		"name":   payload.Name,
	})
}
