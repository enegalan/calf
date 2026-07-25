package httpkit

import (
	"net/http"

	"github.com/gorilla/websocket"
)

// LogsUpgrader upgrades HTTP connections to WebSocket for container log streaming.
var LogsUpgrader = websocket.Upgrader{
	CheckOrigin: isLocalOrNoOrigin,
}

// isLocalOrNoOrigin allows WebSocket upgrades with no Origin header (non-browser clients,
// e.g. the Flutter desktop app) or with an Origin that resolves to the local machine.
func isLocalOrNoOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}

	return IsLocalOrigin(origin)
}
