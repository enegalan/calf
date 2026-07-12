package httpkit

import (
	"net/http"
	"strings"
)

// PartsHandler handles a request with path segments relative to a route prefix.
// The first segment is always the resource identifier when routing under a collection prefix.
type PartsHandler func(http.ResponseWriter, *http.Request, []string)

// Route binds an HTTP method and trailing path segments to a handler.
// Segments are matched against parts[1:] after the resource ID. Use "*" as a wildcard segment.
// An empty Method means the handler performs its own method checks.
type Route struct {
	Segments []string
	Method   string
	Handler  PartsHandler
}

// PathParts returns non-empty path segments after the given prefix.
func PathParts(r *http.Request, prefix string) []string {
	path := strings.TrimPrefix(r.URL.Path, prefix)
	path = strings.Trim(path, "/")
	if path == "" {
		return nil
	}

	raw := strings.Split(path, "/")
	parts := make([]string, 0, len(raw))
	for _, part := range raw {
		if part != "" {
			parts = append(parts, part)
		}
	}

	return parts
}

// MatchSegments reports whether actual path segments match pattern, where "*" matches any segment.
func MatchSegments(actual, pattern []string) bool {
	if len(actual) != len(pattern) {
		return false
	}

	for i, expected := range pattern {
		if expected != "*" && expected != actual[i] {
			return false
		}
	}

	return true
}

// ServeMethods returns a handler that dispatches by HTTP method and answers OPTIONS preflight.
func ServeMethods(handlers map[string]func(http.ResponseWriter, *http.Request)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		handler, ok := handlers[r.Method]
		if !ok {
			MethodNotAllowed(w, r)
			return
		}

		handler(w, r)
	}
}

// ServeMethod returns a handler that accepts only the given HTTP method.
// Use it for leaf handlers reached after a parent already handled OPTIONS.
func ServeMethod(method string, handler func(http.ResponseWriter, *http.Request)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != method {
			MethodNotAllowed(w, r)
			return
		}

		handler(w, r)
	}
}

// ServeRoutes dispatches requests by trailing path segments and HTTP method under prefix.
// fallback handles requests with only a resource ID segment, keyed by HTTP method.
func ServeRoutes(prefix, notFoundMsg string, routes []Route, fallback map[string]PartsHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		parts := PathParts(r, prefix)
		if len(parts) == 0 || parts[0] == "" {
			WriteError(w, http.StatusNotFound, notFoundMsg)
			return
		}

		tail := parts[1:]
		for _, route := range routes {
			if !MatchSegments(tail, route.Segments) {
				continue
			}
			if route.Method != "" && route.Method != r.Method {
				continue
			}

			route.Handler(w, r, parts)
			return
		}

		if len(tail) == 0 && fallback != nil {
			if handler, ok := fallback[r.Method]; ok {
				handler(w, r, parts)
				return
			}
		}

		MethodNotAllowed(w, r)
	}
}

// ServePrefix dispatches by the remaining path after prefix using exact path keys.
// When fallback is non-nil it handles any remaining path that does not match an exact key.
func ServePrefix(prefix string, exact map[string]func(http.ResponseWriter, *http.Request), fallback func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc {
	trimmedPrefix := strings.TrimSuffix(prefix, "/")

	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		remaining := strings.TrimPrefix(r.URL.Path, trimmedPrefix)
		remaining = strings.Trim(remaining, "/")

		if handler, ok := exact[remaining]; ok {
			handler(w, r)
			return
		}

		if fallback != nil {
			fallback(w, r, remaining)
			return
		}

		MethodNotAllowed(w, r)
	}
}
