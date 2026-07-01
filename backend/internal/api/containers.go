package api

import (
	"net/http"
	"strings"
)

func (s *Server) handleContainers(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	containers, err := s.runtime.ListContainers(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, containers)
}

func (s *Server) handleContainerAction(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/v1/containers/")
	parts := strings.Split(path, "/")
	if len(parts) == 0 || parts[0] == "" {
		writeError(w, http.StatusNotFound, "container not found")
		return
	}

	id := parts[0]

	if len(parts) == 2 && parts[1] == "logs" {
		s.handleContainerLogs(w, r, id)
		return
	}

	var err error
	switch r.Method {
	case http.MethodPost:
		if len(parts) != 2 {
			methodNotAllowed(w, r)
			return
		}

		switch parts[1] {
		case "start":
			err = s.runtime.StartContainer(r.Context(), id)
		case "stop":
			err = s.runtime.StopContainer(r.Context(), id)
		default:
			methodNotAllowed(w, r)
			return
		}
	case http.MethodDelete:
		err = s.runtime.RemoveContainer(r.Context(), id)
	default:
		methodNotAllowed(w, r)
		return
	}

	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
