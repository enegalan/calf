package main

import (
	"log"

	"github.com/enegalan/calf/backend/internal/api"
	"github.com/enegalan/calf/backend/internal/config"
)

func main() {
	cfg := config.Load()
	server := api.New(cfg)

	if err := server.Run(); err != nil {
		log.Fatal(err)
	}
}
