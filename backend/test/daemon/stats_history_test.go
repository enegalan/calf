package daemon_test

import (
	"context"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/enegalan/calf/backend/internal/config"
	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/daemon"
	"github.com/enegalan/calf/backend/internal/runtime"
)

func TestStatsHistoryTrimsByRetention(t *testing.T) {
	core := daemon.New(config.Config{}, slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})), runtime.NewMock())
	defer func() {
		_ = core.Shutdown(context.Background())
	}()

	now := time.Now()
	old := now.Add(-constants.StatsHistoryRetention - time.Minute)
	stats := runtime.ContainerStats{
		CPUPerc:  "1.00%",
		MemUsage: "10MB / 1GB",
		MemPerc:  "1.00%",
		NetIO:    "1B / 1B",
		BlockIO:  "1B / 1B",
		PIDs:     "1",
	}

	core.RecordContainerStats("abc123", stats, old)
	core.RecordContainerStats("abc123", stats, now)

	samples := core.ContainerStatsSamples("abc123")
	if len(samples) != 1 {
		t.Fatalf("expected 1 retained sample, got %d", len(samples))
	}
	if samples[0].T != now.UnixMilli() {
		t.Fatalf("expected latest sample timestamp %d, got %d", now.UnixMilli(), samples[0].T)
	}
}

func TestStatsHistoryForgetClearsSamples(t *testing.T) {
	core := daemon.New(config.Config{}, slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})), runtime.NewMock())
	defer func() {
		_ = core.Shutdown(context.Background())
	}()

	core.RecordContainerStats("abc123", runtime.ContainerStats{CPUPerc: "2.00%"}, time.Now())
	if len(core.ContainerStatsSamples("abc123")) == 0 {
		t.Fatal("expected samples before forget")
	}

	core.ForgetContainerStats("abc123")
	if len(core.ContainerStatsSamples("abc123")) != 0 {
		t.Fatal("expected no samples after forget")
	}
}
