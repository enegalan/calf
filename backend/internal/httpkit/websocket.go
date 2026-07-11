package httpkit

import (
	"net/http"

	"github.com/gorilla/websocket"
)

// LogsUpgrader upgrades HTTP connections to WebSocket for container log streaming.
var LogsUpgrader = websocket.Upgrader{
	CheckOrigin: func(_ *http.Request) bool {
		return true
	},
}
