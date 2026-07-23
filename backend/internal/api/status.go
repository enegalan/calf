package api

import (
	"net/http"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/version"
)

// statusResources is the live CPU/RAM/disk usage block on GET /v1/status.
type statusResources struct {
	CpuPercent          float64 `json:"cpu_percent"`
	MemoryUsedBytes     int64   `json:"memory_used_bytes"`
	MemoryReservedBytes int64   `json:"memory_reserved_bytes"`
	DiskUsedBytes       int64   `json:"disk_used_bytes"`
	DiskReservedBytes   int64   `json:"disk_reserved_bytes"`
}

// statusResponse represents the JSON payload for GET /v1/status.
type statusResponse struct {
	Version       string          `json:"version"`
	UptimeSeconds int64           `json:"uptime_seconds"`
	ListenAddr    string          `json:"listen_addr"`
	LogLevel      string          `json:"log_level"`
	Runtime       runtime.Status  `json:"runtime"`
	Resources     statusResources `json:"resources"`
}

// handleStatus serves GET /v1/status with version, uptime, runtime state, and resources.
func (g *Gateway) handleStatus(w http.ResponseWriter, r *http.Request) {
	runtimeStatus, err := g.backend.Runtime.Status(r.Context())
	if err != nil {
		httpkit.WriteError(w, http.StatusInternalServerError, err.Error())
		return
	}

	g.backend.CfgMu.RLock()
	cfg := g.backend.Cfg
	g.backend.CfgMu.RUnlock()

	resources := statusResources{
		MemoryReservedBytes: int64(cfg.MemoryGB) * constants.BytesPerGiB,
		DiskReservedBytes:   int64(cfg.DiskGB) * constants.BytesPerGiB,
	}
	if usage, usageErr := g.backend.Runtime.ResourceUsage(r.Context()); usageErr == nil {
		resources.CpuPercent = usage.CpuPercent
		resources.MemoryUsedBytes = usage.MemoryUsedBytes
		resources.DiskUsedBytes = usage.DiskUsedBytes
	}

	httpkit.WriteJSON(w, http.StatusOK, statusResponse{
		Version:       version.Version,
		UptimeSeconds: int64(time.Since(g.backend.StartTime).Seconds()),
		ListenAddr:    cfg.ListenAddr,
		LogLevel:      cfg.LogLevel,
		Runtime:       runtimeStatus,
		Resources:     resources,
	})
}
