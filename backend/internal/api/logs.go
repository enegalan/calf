package api

import (
	"context"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
)

const (
	logsPongWait   = 60 * time.Second
	logsPingPeriod = (logsPongWait * 9) / 10
	logsWriteWait  = 10 * time.Second
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

	writer := newWSWriter(conn, logsWriteWait)
	lines, unsubscribe := s.logBroadcaster.subscribe(s.runtime, id)
	defer unsubscribe()

	conn.SetReadDeadline(time.Now().Add(logsPongWait))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(logsPongWait))
		return nil
	})

	go func() {
		for {
			if _, _, readErr := conn.ReadMessage(); readErr != nil {
				cancel()
				return
			}
		}
	}()

	pingTicker := time.NewTicker(logsPingPeriod)
	defer pingTicker.Stop()

	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-pingTicker.C:
				if writeErr := writer.writeMessage(websocket.PingMessage, nil); writeErr != nil {
					cancel()
					return
				}
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
