package api

import (
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
)

type Server struct {
	cfg       config.Config
	startTime time.Time
}

func New(cfg config.Config) *Server {
	return &Server{
		cfg:       cfg,
		startTime: time.Now(),
	}
}

func (s *Server) Run() error {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/health", s.handleHealth)
	mux.HandleFunc("/v1/status", s.handleStatus)

	handler := corsMiddleware(mux)

	log.Printf("listening on %s", s.cfg.ListenAddr)
	return http.ListenAndServe(s.cfg.ListenAddr, handler)
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func (s *Server) Addr() string {
	return fmt.Sprintf("http://localhost%s", s.cfg.ListenAddr)
}
