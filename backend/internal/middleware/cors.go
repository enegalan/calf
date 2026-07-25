package middleware

import (
	"net/http"

	"github.com/enegalan/calf/backend/internal/httpkit"
)

// CORS scopes cross-origin access to the local desktop app: only requests whose Origin
// is localhost/127.0.0.1/[::1] (any port) get the Allow-Origin headers reflected back.
// Remote origins receive no CORS headers, which browsers treat as denied. OPTIONS
// preflight requests are always short-circuited with 204.
func CORS() Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if origin := r.Header.Get("Origin"); httpkit.IsLocalOrigin(origin) {
				w.Header().Set("Access-Control-Allow-Origin", origin)
				w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
				w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
			}

			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}
