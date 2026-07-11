package api

import (
	"context"
	"net/http"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/gorilla/websocket"
)

// handleContainerLogs serves GET /v1/containers/{id}/logs by upgrading to a log-streaming WebSocket.
func (g *Gateway) handleContainerLogs(w http.ResponseWriter, r *http.Request, id string) {
	conn, err := httpkit.LogsUpgrader.Upgrade(w, r, nil)
	if err != nil {
		g.logger.Error("websocket upgrade failed", "error", err)
		return
	}
	defer conn.Close()

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	writer := httpkit.NewWSWriter(conn, constants.LogsWriteWait)
	lines, unsubscribe := g.backend.SubscribeLogs(id)
	defer unsubscribe()

	conn.SetReadDeadline(time.Now().Add(constants.LogsPongWait))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(constants.LogsPongWait))
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

	pingTicker := time.NewTicker(constants.LogsPingPeriod)
	defer pingTicker.Stop()

	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-pingTicker.C:
				if writeErr := writer.WriteMessage(websocket.PingMessage, nil); writeErr != nil {
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
			if writeErr := writer.WriteMessage(websocket.TextMessage, []byte(line)); writeErr != nil {
				return
			}
		}
	}
}
