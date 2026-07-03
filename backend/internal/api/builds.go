package api

import (
	"fmt"
	"net/http"
	"time"

	"github.com/enegalan/calf/backend/internal/runtime"
)

func (s *Server) handleBuilds(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	switch r.Method {
	case http.MethodGet:
		s.buildsMu.RLock()
		builds := append([]runtime.Build{}, s.builds...)
		s.buildsMu.RUnlock()
		writeJSON(w, http.StatusOK, builds)
	case http.MethodPost:
		var payload struct {
			Context    string `json:"context"`
			Tag        string `json:"tag"`
			Dockerfile string `json:"dockerfile"`
		}

		if err := jsonDecode(r, &payload); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		if payload.Context == "" || payload.Tag == "" {
			writeError(w, http.StatusBadRequest, "context and tag are required")
			return
		}

		build := s.newBuild(payload.Context, payload.Tag, "running")
		if err := s.runtime.RunBuild(r.Context(), payload.Context, payload.Tag, payload.Dockerfile); err != nil {
			s.updateBuildStatus(build.ID, "failed")
			if writeRuntimeError(w, err) {
				return
			}

			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}

		s.updateBuildStatus(build.ID, "success")
		writeJSON(w, http.StatusOK, build)
	default:
		methodNotAllowed(w, r)
	}
}

func (s *Server) newBuild(contextPath, tag, status string) runtime.Build {
	s.buildsMu.Lock()
	defer s.buildsMu.Unlock()

	s.buildSeq++
	build := runtime.Build{
		ID:        fmt.Sprintf("build-%d", s.buildSeq),
		Tag:       tag,
		Context:   contextPath,
		Status:    status,
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
	}
	s.builds = append([]runtime.Build{build}, s.builds...)

	return build
}

func (s *Server) updateBuildStatus(id, status string) {
	s.buildsMu.Lock()
	defer s.buildsMu.Unlock()

	for index, build := range s.builds {
		if build.ID == id {
			s.builds[index].Status = status
			return
		}
	}
}
