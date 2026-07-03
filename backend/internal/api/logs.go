package api

import (
	"context"
	"net/http"

	"github.com/gorilla/websocket"
)

func (s *Server) handleContainerLogs(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		methodNotAllowed(w, r)
		return
	}

	s.handleContainerLogsWebSocket(w, r, id)
}

func (s *Server) handleContainerLogsWebSocket(w http.ResponseWriter, r *http.Request, id string) {
	conn, err := logsUpgrader.Upgrade(w, r, nil)
	if err != nil {
		s.logger.Error("websocket upgrade failed", "error", err)
		return
	}
	defer conn.Close()

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	go func() {
		for {
			if _, _, readErr := conn.ReadMessage(); readErr != nil {
				cancel()
				return
			}
		}
	}()

	err = s.runtime.StreamLogs(ctx, id, func(line string) {
		if writeErr := conn.WriteMessage(websocket.TextMessage, []byte(line)); writeErr != nil {
			cancel()
		}
	})
	if err != nil && ctx.Err() == nil {
		_ = conn.WriteMessage(websocket.TextMessage, []byte("error: "+err.Error()))
	}
}
