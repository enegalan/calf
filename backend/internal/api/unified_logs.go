package api

import (
	"context"
	"net/http"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/gorilla/websocket"
)

// handleUnifiedLogs serves GET /v1/logs as a WebSocket of all running container logs.
func (g *Gateway) handleUnifiedLogs(w http.ResponseWriter, r *http.Request) {
	conn, err := httpkit.LogsUpgrader.Upgrade(w, r, nil)
	if err != nil {
		g.logger.Error("websocket upgrade failed", "error", err)
		return
	}
	defer conn.Close()

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	lines, unsubscribe, err := g.backend.SubscribeAllLogs(ctx)
	if err != nil {
		_ = conn.WriteMessage(websocket.TextMessage, []byte("error: "+err.Error()))
		return
	}
	defer unsubscribe()

	writer := httpkit.NewWSWriter(conn, constants.LogsWriteWait)
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

	for {
		select {
		case <-ctx.Done():
			return
		case <-pingTicker.C:
			if writeErr := writer.WriteMessage(websocket.PingMessage, nil); writeErr != nil {
				return
			}
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
