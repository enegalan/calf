package httpkit

import (
	"net"
	"net/url"
)

// IsLocalOrigin reports whether an HTTP Origin header value points at localhost,
// 127.0.0.1, or [::1] on any port. Used to scope CORS and WebSocket origin checks
// to the local desktop app instead of allowing arbitrary remote origins.
func IsLocalOrigin(origin string) bool {
	if origin == "" {
		return false
	}

	parsed, err := url.Parse(origin)
	if err != nil {
		return false
	}

	return IsLocalHost(parsed.Hostname())
}

// IsLocalHost reports whether host (a hostname or IP, without port) refers to the local machine.
func IsLocalHost(host string) bool {
	switch host {
	case "localhost", "127.0.0.1", "::1":
		return true
	}

	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
