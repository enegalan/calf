package middleware

import (
	"log/slog"
	"net/http"

	"github.com/enegalan/calf/backend/internal/httpkit"
)

// Recovery catches panics, logs them, and returns a 500 response.
func Recovery(logger *slog.Logger) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if recovered := recover(); recovered != nil {
					logger.Error("panic recovered", "error", recovered)
					httpkit.WriteError(w, http.StatusInternalServerError, "internal server error")
				}
			}()

			next.ServeHTTP(w, r)
		})
	}
}
