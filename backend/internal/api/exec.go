package api

import (
	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"context"
	"encoding/json"
	"io"
	"net/http"

	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/gorilla/websocket"
)

// handleContainerExec routes GET to the interactive WebSocket exec and POST to one-shot exec.
func (g *Gateway) handleContainerExec(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method == http.MethodGet {
		g.handleContainerExecWebSocket(w, r, id)
		return
	}

	if r.Method != http.MethodPost {
		httpkit.MethodNotAllowed(w, r)
		return
	}

	g.handleContainerExecOnce(w, r, id)
}

// handleContainerExecWebSocket upgrades to a WebSocket and attaches an interactive PTY exec session.
func (g *Gateway) handleContainerExecWebSocket(w http.ResponseWriter, r *http.Request, id string) {
	conn, err := httpkit.LogsUpgrader.Upgrade(w, r, nil)
	if err != nil {
		g.logger.Error("exec websocket upgrade failed", "error", err)
		return
	}
	defer conn.Close()

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	writer := httpkit.NewWSWriter(conn, constants.LogsWriteWait)
	stdinReader, stdinWriter := io.Pipe()
	resizeCh := make(chan runtime.ExecResize, 4)

	go func() {
		defer close(resizeCh)
		defer stdinWriter.Close()
		for {
			messageType, payload, readErr := conn.ReadMessage()
			if readErr != nil {
				cancel()
				return
			}

			if messageType == websocket.TextMessage {
				if size, ok := parseExecResizeMessage(payload); ok {
					select {
					case resizeCh <- size:
					default:
					}
					continue
				}
			}

			if _, writeErr := stdinWriter.Write(payload); writeErr != nil {
				cancel()
				return
			}
		}
	}()

	attachErr := g.backend.Runtime.AttachExec(ctx, id, stdinReader, func(chunk []byte) {
		if writeErr := writer.WriteMessage(websocket.BinaryMessage, chunk); writeErr != nil {
			cancel()
		}
	}, resizeCh)
	if attachErr != nil && ctx.Err() == nil {
		_ = writer.WriteMessage(websocket.TextMessage, []byte("error: "+attachErr.Error()))
	}
}

// parseExecResizeMessage decodes a JSON resize control message from the exec WebSocket client.
func parseExecResizeMessage(payload []byte) (runtime.ExecResize, bool) {
	var message struct {
		Type string `json:"type"`
		Rows uint16 `json:"rows"`
		Cols uint16 `json:"cols"`
	}
	if err := json.Unmarshal(payload, &message); err != nil {
		return runtime.ExecResize{}, false
	}
	if message.Type != "resize" || message.Rows == 0 || message.Cols == 0 {
		return runtime.ExecResize{}, false
	}

	return runtime.ExecResize{Rows: message.Rows, Cols: message.Cols}, true
}
