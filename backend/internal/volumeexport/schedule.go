package volumeexport

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/enegalan/calf/backend/internal/config"
)

// DayTimeSchedule represents a day and time schedule.
type DayTimeSchedule struct {
	Day   int      `json:"day"`
	Times []string `json:"times"`
}

// Schedule represents an export schedule.
type Schedule struct {
	ID         string            `json:"id"`
	Volume     string            `json:"volume"`
	Enabled    bool              `json:"enabled"`
	DayTimes   []DayTimeSchedule `json:"day_times,omitempty"`
	Type       string            `json:"type"`
	FileName   string            `json:"file_name,omitempty"`
	Folder     string            `json:"folder,omitempty"`
	ImageRef   string            `json:"image_ref,omitempty"`
	CreatedAt  string            `json:"created_at"`
	LastRunAt  string            `json:"last_run_at,omitempty"`
	NextRunAt  string            `json:"next_run_at,omitempty"`
	LastStatus string            `json:"last_status,omitempty"`
	LastError  string            `json:"last_error,omitempty"`
}

// ScheduleStore represents a store of export schedules.
type ScheduleStore struct {
	root string
}

// NewScheduleStore creates a ScheduleStore rooted at ~/.config/calf/mounts/volume-export-schedules.
func NewScheduleStore() (*ScheduleStore, error) {
	root, err := config.MountsSubdir("volume-export-schedules")
	if err != nil {
		return nil, err
	}

	return &ScheduleStore{root: root}, nil
}

// List returns all export schedules for volumeName, sorted newest first.
func (s *ScheduleStore) List(volumeName string) ([]Schedule, error) {
	path := s.volumePath(volumeName)
	payload, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return []Schedule{}, nil
		}

		return nil, fmt.Errorf("read schedules for %s: %w", volumeName, err)
	}

	var schedules []Schedule
	if err := json.Unmarshal(payload, &schedules); err != nil {
		return nil, fmt.Errorf("decode schedules for %s: %w", volumeName, err)
	}

	sort.Slice(schedules, func(i, j int) bool {
		return schedules[i].CreatedAt > schedules[j].CreatedAt
	})

	for index := range schedules {
		NormalizeSchedule(&schedules[index])
	}

	return schedules, nil
}

// ListAll returns export schedules from every volume file, skipping unreadable entries.
func (s *ScheduleStore) ListAll() ([]Schedule, error) {
	entries, err := os.ReadDir(s.root)
	if err != nil {
		if os.IsNotExist(err) {
			return []Schedule{}, nil
		}

		return nil, fmt.Errorf("list schedule files: %w", err)
	}

	schedules := make([]Schedule, 0)
	var skipped []error
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}

		path := filepath.Join(s.root, entry.Name())
		payload, err := os.ReadFile(path)
		if err != nil {
			skipped = append(skipped, fmt.Errorf("read %s: %w", entry.Name(), err))
			continue
		}

		var volumeSchedules []Schedule
		if err := json.Unmarshal(payload, &volumeSchedules); err != nil {
			skipped = append(skipped, fmt.Errorf("decode %s: %w", entry.Name(), err))
			continue
		}

		schedules = append(schedules, volumeSchedules...)
	}

	for index := range schedules {
		NormalizeSchedule(&schedules[index])
	}

	return schedules, errors.Join(skipped...)
}

// Get returns the export schedule with id for volumeName.
func (s *ScheduleStore) Get(volumeName, id string) (Schedule, error) {
	schedules, err := s.List(volumeName)
	if err != nil {
		return Schedule{}, err
	}

	for _, schedule := range schedules {
		if schedule.ID == id {
			return schedule, nil
		}
	}

	return Schedule{}, fmt.Errorf("schedule %s not found", id)
}

// Save inserts or updates an export schedule and persists it to disk.
func (s *ScheduleStore) Save(schedule Schedule) error {
	if strings.TrimSpace(schedule.Volume) == "" {
		return fmt.Errorf("volume is required")
	}

	if strings.TrimSpace(schedule.ID) == "" {
		return fmt.Errorf("id is required")
	}

	NormalizeSchedule(&schedule)

	schedules, err := s.List(schedule.Volume)
	if err != nil {
		return err
	}

	found := false
	for index, existing := range schedules {
		if existing.ID == schedule.ID {
			schedules[index] = schedule
			found = true
			break
		}
	}

	if !found {
		schedules = append(schedules, schedule)
	}

	return s.writeVolume(schedule.Volume, schedules)
}

// Delete removes the export schedule with id from volumeName.
func (s *ScheduleStore) Delete(volumeName, id string) error {
	schedules, err := s.List(volumeName)
	if err != nil {
		return err
	}

	filtered := make([]Schedule, 0, len(schedules))
	found := false
	for _, schedule := range schedules {
		if schedule.ID == id {
			found = true
			continue
		}

		filtered = append(filtered, schedule)
	}

	if !found {
		return fmt.Errorf("schedule %s not found", id)
	}

	if len(filtered) == 0 {
		return os.Remove(s.volumePath(volumeName))
	}

	return s.writeVolume(volumeName, filtered)
}

// NewID generates a unique schedule identifier for volumeName.
func (s *ScheduleStore) NewID(volumeName string) string {
	return newResourceID("schedule", volumeName)
}

// writeVolume persists the schedule list for volumeName as JSON.
func (s *ScheduleStore) writeVolume(volumeName string, schedules []Schedule) error {
	path := s.volumePath(volumeName)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create schedule dir: %w", err)
	}

	payload, err := json.MarshalIndent(schedules, "", "  ")
	if err != nil {
		return fmt.Errorf("encode schedules: %w", err)
	}

	if err := os.WriteFile(path, payload, 0o644); err != nil {
		return fmt.Errorf("write schedules: %w", err)
	}

	return nil
}

// volumePath returns the on-disk JSON path for volumeName's schedules.
func (s *ScheduleStore) volumePath(volumeName string) string {
	return filepath.Join(s.root, sanitizeName(volumeName)+".json")
}
