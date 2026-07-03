package api

import (
	"sync"

	"github.com/gorilla/websocket"
)

type wsWriter struct {
	conn *websocket.Conn
	mu   sync.Mutex
}

func newWSWriter(conn *websocket.Conn) *wsWriter {
	return &wsWriter{conn: conn}
}

func (w *wsWriter) writeMessage(messageType int, data []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.conn.WriteMessage(messageType, data)
}
