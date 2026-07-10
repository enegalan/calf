package volumeexport

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	// ScheduleRunGrace is how long after the scheduled minute a run slot stays open.
	// It matches the scheduler tick interval so a once-per-minute poll cannot miss the slot.
	ScheduleRunGrace = time.Minute
)

type DayTimeSchedule struct {
	Day   int      `json:"day"`
	Times []string `json:"times"`
}

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

type ScheduleStore struct {
	root string
}

func NewScheduleStore() (*ScheduleStore, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("resolve home dir: %w", err)
	}

	root := filepath.Join(home, ".config", "calf", "mounts", "volume-export-schedules")
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, fmt.Errorf("create schedule root: %w", err)
	}

	return &ScheduleStore{root: root}, nil
}

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

func (s *ScheduleStore) NewID(volumeName string) string {
	return fmt.Sprintf("schedule-%s-%d", sanitizeName(volumeName), time.Now().UnixNano())
}

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

func (s *ScheduleStore) volumePath(volumeName string) string {
	return filepath.Join(s.root, sanitizeName(volumeName)+".json")
}
