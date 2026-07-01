package main

import (
	"log/slog"
	"os"

	"github.com/enegalan/calf/backend/internal/api"
	"github.com/enegalan/calf/backend/internal/config"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		slog.Error("failed to load config", "error", err)
		os.Exit(1)
	}

	logger := config.NewLogger(cfg.LogLevel)
	server := api.New(cfg, logger)

	if err := server.Run(); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}
