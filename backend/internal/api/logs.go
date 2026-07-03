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

	writer := newWSWriter(conn)
	lines, unsubscribe := s.logBroadcaster.subscribe(s.runtime, id)
	defer unsubscribe()

	go func() {
		for {
			if _, _, readErr := conn.ReadMessage(); readErr != nil {
				cancel()
				return
			}
		}
	}()

	for {
		select {
		case <-ctx.Done():
			return
		case line, ok := <-lines:
			if !ok {
				return
			}
			if writeErr := writer.writeMessage(websocket.TextMessage, []byte(line)); writeErr != nil {
				return
			}
		}
	}
}
