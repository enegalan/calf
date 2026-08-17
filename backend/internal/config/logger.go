package config

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

var (
	logLevel  slog.LevelVar
	logFile   *rotatingFile
	logFileMu sync.Mutex
)

// NewLogger builds a text slog.Logger writing to stdout and ~/.config/calf/logs/calf.log.
func NewLogger(level string) *slog.Logger {
	normalized, err := NormalizeLogLevel(level)
	if err != nil {
		normalized = "info"
	}
	logLevel.Set(parseLogLevel(normalized))

	writer := io.MultiWriter(os.Stdout, ReopenLogFile())
	logger := slog.New(slog.NewTextHandler(writer, &slog.HandlerOptions{
		Level: &logLevel,
	}))
	slog.SetDefault(logger)
	return logger
}

// SetLogLevel changes the process log level without rebuilding the logger.
func SetLogLevel(level string) {
	normalized, err := NormalizeLogLevel(level)
	if err != nil {
		normalized = "info"
	}
	logLevel.Set(parseLogLevel(normalized))
}

// NormalizeLogLevel maps a config log_level string to debug, info, warn, or error.
func NormalizeLogLevel(level string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(level)) {
	case "debug":
		return "debug", nil
	case "info":
		return "info", nil
	case "warn", "warning":
		return "warn", nil
	case "error":
		return "error", nil
	default:
		return "", fmt.Errorf("log_level: must be debug, info, warn, or error")
	}
}

// ClearLogFile removes the daemon log and rotated backup so a later failure can be captured cleanly.
func ClearLogFile() error {
	logFileMu.Lock()
	defer logFileMu.Unlock()
	if logFile != nil {
		return logFile.Clear()
	}
	path, err := LogFilePath()
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	if err := os.Remove(path + ".1"); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// ReopenLogFile closes and reopens the daemon log file after it was deleted.
func ReopenLogFile() io.Writer {
	logFileMu.Lock()
	defer logFileMu.Unlock()
	path, pathErr := LogFilePath()
	if logFile != nil {
		if pathErr == nil && logFile.path == path {
			if err := logFile.Reopen(); err == nil {
				return logFile
			}
		}
		_ = logFile.Close()
		logFile = nil
	}
	return openLogFileLocked()
}

// parseLogLevel maps a config log_level string to slog.Level, defaulting to info.
func parseLogLevel(level string) slog.Level {
	switch strings.ToLower(strings.TrimSpace(level)) {
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

// openLogFileLocked opens the log file. Caller must hold logFileMu.
func openLogFileLocked() io.Writer {
	path, err := LogFilePath()
	if err != nil {
		return io.Discard
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return io.Discard
	}

	file, err := newRotatingFile(path)
	if err != nil {
		return io.Discard
	}
	logFile = file
	return file
}
