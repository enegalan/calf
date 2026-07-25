package httpkit

import (
	"context"
	"net/http"
	"time"
)

// WithTimeout returns a shallow copy of r whose context is derived from r.Context() bound to d,
// plus the associated cancel func. Callers must invoke cancel (typically via defer) right after
// calling WithTimeout to release the timer once the request has been handled.
func WithTimeout(r *http.Request, d time.Duration) (*http.Request, context.CancelFunc) {
	ctx, cancel := context.WithTimeout(r.Context(), d)
	return r.WithContext(ctx), cancel
}
