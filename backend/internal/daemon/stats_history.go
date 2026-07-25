package daemon

import (
	"strings"
	"sync"
	"time"

	"github.com/enegalan/calf/backend/internal/runtime"
)

// StatsSample is one timestamped container resource snapshot for history charts.
type StatsSample struct {
	T        int64  `json:"t"`
	CPUPerc  string `json:"cpu_percent"`
	MemUsage string `json:"mem_usage"`
	MemPerc  string `json:"mem_percent"`
	NetIO    string `json:"net_io"`
	BlockIO  string `json:"block_io"`
	PIDs     string `json:"pids"`
}

// statsHistory holds a rolling in-memory stats window per container ID.
type statsHistory struct {
	mu     sync.RWMutex
	byID   map[string][]StatsSample
	retain time.Duration
}

// newStatsHistory creates an empty stats history store with the given retention window.
func newStatsHistory(retain time.Duration) *statsHistory {
	return &statsHistory{
		byID:   make(map[string][]StatsSample),
		retain: retain,
	}
}

// Append records a stats snapshot for id and drops samples older than retention.
func (h *statsHistory) Append(id string, stats runtime.ContainerStats, at time.Time) {
	id = strings.TrimSpace(id)
	if id == "" {
		return
	}

	sample := StatsSample{
		T:        at.UnixMilli(),
		CPUPerc:  stats.CPUPerc,
		MemUsage: stats.MemUsage,
		MemPerc:  stats.MemPerc,
		NetIO:    stats.NetIO,
		BlockIO:  stats.BlockIO,
		PIDs:     stats.PIDs,
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	key := h.resolveKeyLocked(id)
	if key == "" {
		key = id
	}

	cutoff := at.Add(-h.retain).UnixMilli()
	previous := h.byID[key]
	next := make([]StatsSample, 0, len(previous)+1)
	for _, existing := range previous {
		if existing.T >= cutoff {
			next = append(next, existing)
		}
	}
	next = append(next, sample)
	h.byID[key] = next
}

// Samples returns a copy of retained samples for id (exact or prefix ID match).
func (h *statsHistory) Samples(id string) []StatsSample {
	id = strings.TrimSpace(id)
	if id == "" {
		return nil
	}

	h.mu.RLock()
	defer h.mu.RUnlock()

	key := h.resolveKeyLocked(id)
	if key == "" {
		return nil
	}

	src := h.byID[key]
	out := make([]StatsSample, len(src))
	copy(out, src)
	return out
}

// Forget removes all retained samples for id (exact or prefix ID match).
func (h *statsHistory) Forget(id string) {
	id = strings.TrimSpace(id)
	if id == "" {
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	for key := range h.byID {
		if containerIDMatch(key, id) {
			delete(h.byID, key)
		}
	}
}

// RetainOnly drops history for container IDs not present in keep.
func (h *statsHistory) RetainOnly(keep map[string]struct{}) {
	h.mu.Lock()
	defer h.mu.Unlock()

	for key := range h.byID {
		if containerIDInSet(key, keep) {
			continue
		}
		delete(h.byID, key)
	}
}

// resolveKeyLocked finds the map key for id. Caller must hold h.mu.
func (h *statsHistory) resolveKeyLocked(id string) string {
	if _, ok := h.byID[id]; ok {
		return id
	}
	for key := range h.byID {
		if containerIDMatch(key, id) {
			return key
		}
	}
	return ""
}

// containerIDMatch reports whether a and b refer to the same container ID prefix.
func containerIDMatch(a, b string) bool {
	return a == b || strings.HasPrefix(a, b) || strings.HasPrefix(b, a)
}

// containerIDInSet reports whether id matches any key in keep (exact or prefix).
func containerIDInSet(id string, keep map[string]struct{}) bool {
	if _, ok := keep[id]; ok {
		return true
	}
	for candidate := range keep {
		if containerIDMatch(id, candidate) {
			return true
		}
	}
	return false
}
