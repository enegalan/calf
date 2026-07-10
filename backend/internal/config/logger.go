package config

import (
	"log/slog"
	"os"
	"strings"
)

// NewLogger builds a text slog.Logger writing to stdout at the given level name.
func NewLogger(level string) *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: parseLogLevel(level),
	}))
}

// parseLogLevel maps a config log_level string to slog.Level, defaulting to info.
func parseLogLevel(level string) slog.Level {
	switch strings.ToLower(level) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
