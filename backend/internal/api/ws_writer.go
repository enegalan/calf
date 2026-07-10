package api

import (
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type wsWriter struct {
	conn      *websocket.Conn
	mu        sync.Mutex
	writeWait time.Duration
}

// newWSWriter creates a mutex-guarded WebSocket writer with per-write deadlines.
func newWSWriter(conn *websocket.Conn, writeWait time.Duration) *wsWriter {
	return &wsWriter{conn: conn, writeWait: writeWait}
}

// writeMessage sends a WebSocket frame under the writer lock, applying writeWait when configured.
func (w *wsWriter) writeMessage(messageType int, data []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()

	if w.writeWait > 0 {
		if err := w.conn.SetWriteDeadline(time.Now().Add(w.writeWait)); err != nil {
			return err
		}
	}

	return w.conn.WriteMessage(messageType, data)
}
