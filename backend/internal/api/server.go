package api

import (
	"fmt"
	"log"
	"net/http"

	"github.com/enegalan/calf/backend/internal/config"
)

type Server struct {
	cfg config.Config
}

func New(cfg config.Config) *Server {
	return &Server{cfg: cfg}
}

func (s *Server) Run() error {
	mux := http.NewServeMux()
	mux.HandleFunc("/hello", helloHandler)

	log.Printf("listening on %s", s.cfg.ListenAddr)
	return http.ListenAndServe(s.cfg.ListenAddr, mux)
}

func helloHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	fmt.Fprint(w, "Hello, World!")
}
