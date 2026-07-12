package httpkit

import (
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// WSWriter is a mutex-guarded WebSocket writer with per-write deadlines.
type WSWriter struct {
	conn      *websocket.Conn
	mu        sync.Mutex
	writeWait time.Duration
}

// NewWSWriter creates a mutex-guarded WebSocket writer with per-write deadlines.
func NewWSWriter(conn *websocket.Conn, writeWait time.Duration) *WSWriter {
	return &WSWriter{conn: conn, writeWait: writeWait}
}

// WriteMessage sends a WebSocket frame under the writer lock, applying writeWait when configured.
func (w *WSWriter) WriteMessage(messageType int, data []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()

	if w.writeWait > 0 {
		if err := w.conn.SetWriteDeadline(time.Now().Add(w.writeWait)); err != nil {
			return err
		}
	}

	return w.conn.WriteMessage(messageType, data)
}
