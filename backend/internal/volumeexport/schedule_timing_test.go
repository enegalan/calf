package volumeexport

import (
	"testing"
	"time"
)

func TestComputeNextRunCronSameDay(t *testing.T) {
	loc := time.Local
	now := time.Date(2026, 7, 5, 10, 0, 0, 0, loc)

	schedule := Schedule{
		Enabled:    true,
		DaysOfWeek: []int{int(now.Weekday())},
		Times:      []string{"15:04", "18:30"},
		Type:       TypeLocalFile,
		Folder:     "/tmp",
	}

	next, err := ComputeNextRun(schedule, now)
	if err != nil {
		t.Fatalf("ComputeNextRun() error: %v", err)
	}

	expected := time.Date(2026, 7, 5, 15, 4, 0, 0, loc)
	if !next.Equal(expected) {
		t.Fatalf("expected %v, got %v", expected, next)
	}
}

func TestComputeNextRunCronRollsToNextSelectedDay(t *testing.T) {
	loc := time.Local
	now := time.Date(2026, 7, 5, 20, 0, 0, 0, loc)

	schedule := Schedule{
		Enabled:    true,
		DaysOfWeek: []int{int(time.Monday)},
		Times:      []string{"09:30"},
		Type:       TypeLocalFile,
		Folder:     "/tmp",
	}

	next, err := ComputeNextRun(schedule, now)
	if err != nil {
		t.Fatalf("ComputeNextRun() error: %v", err)
	}

	expected := time.Date(2026, 7, 6, 9, 30, 0, 0, loc)
	if !next.Equal(expected) {
		t.Fatalf("expected %v, got %v", expected, next)
	}
}

func TestComputeNextRunDisabledReturnsZero(t *testing.T) {
	now := time.Now()

	next, err := ComputeNextRun(Schedule{Enabled: false}, now)
	if err != nil {
		t.Fatalf("ComputeNextRun() error: %v", err)
	}

	if !next.IsZero() {
		t.Fatalf("expected zero time for disabled schedule, got %v", next)
	}
}

func TestNormalizeScheduleLegacyDaily(t *testing.T) {
	schedule := Schedule{
		Frequency: FrequencyDaily,
		TimeOfDay: "03:00",
	}

	NormalizeSchedule(&schedule)

	if len(schedule.DayTimes) != 7 {
		t.Fatalf("expected 7 day entries, got %d", len(schedule.DayTimes))
	}

	for _, entry := range schedule.DayTimes {
		if len(entry.Times) != 1 || entry.Times[0] != "03:00" {
			t.Fatalf("unexpected times for day %d: %#v", entry.Day, entry.Times)
		}
	}
}

func TestComputeNextRunPerDayDifferentTimes(t *testing.T) {
	loc := time.Local
	now := time.Date(2026, 7, 5, 10, 0, 0, 0, loc)

	schedule := Schedule{
		Enabled: true,
		DayTimes: []DayTimeSchedule{
			{Day: int(time.Monday), Times: []string{"15:04", "18:30"}},
			{Day: int(time.Tuesday), Times: []string{"09:30"}},
		},
		Type:   TypeLocalFile,
		Folder: "/tmp",
	}

	next, err := ComputeNextRun(schedule, now)
	if err != nil {
		t.Fatalf("ComputeNextRun() error: %v", err)
	}

	expected := time.Date(2026, 7, 6, 15, 4, 0, 0, loc)
	if !next.Equal(expected) {
		t.Fatalf("expected %v, got %v", expected, next)
	}
}

func TestComputeNextRunIncludesCurrentMinuteSlot(t *testing.T) {
	loc := time.Local
	now := time.Date(2026, 7, 5, 17, 11, 30, 0, loc)

	schedule := Schedule{
		Enabled: true,
		DayTimes: []DayTimeSchedule{
			{Day: int(now.Weekday()), Times: []string{"17:11", "17:20"}},
		},
		Type:   TypeLocalFile,
		Folder: "/tmp",
	}

	next, err := ComputeNextRun(schedule, now)
	if err != nil {
		t.Fatalf("ComputeNextRun() error: %v", err)
	}

	expected := time.Date(2026, 7, 5, 17, 11, 0, 0, loc)
	if !next.Equal(expected) {
		t.Fatalf("expected %v, got %v", expected, next)
	}
}

func TestComputeNextRunAfterRunSkipsCurrentSlot(t *testing.T) {
	loc := time.Local
	now := time.Date(2026, 7, 5, 17, 11, 30, 0, loc)

	schedule := Schedule{
		Enabled: true,
		DayTimes: []DayTimeSchedule{
			{Day: int(now.Weekday()), Times: []string{"17:11", "17:20"}},
		},
		Type:   TypeLocalFile,
		Folder: "/tmp",
	}

	next, err := ComputeNextRunAfterRun(schedule, now)
	if err != nil {
		t.Fatalf("ComputeNextRunAfterRun() error: %v", err)
	}

	expected := time.Date(2026, 7, 5, 17, 20, 0, 0, loc)
	if !next.Equal(expected) {
		t.Fatalf("expected %v, got %v", expected, next)
	}
}

func TestScheduleDueWithinGraceWindow(t *testing.T) {
	loc := time.Local
	nextRun := time.Date(2026, 7, 5, 17, 11, 0, 0, loc).UTC().Format(time.RFC3339)

	if !ScheduleDue(nextRun, time.Date(2026, 7, 5, 17, 11, 45, 0, loc)) {
		t.Fatalf("expected schedule to be due inside grace window")
	}

	if !ScheduleDue(nextRun, time.Date(2026, 7, 5, 17, 12, 0, 0, loc)) {
		t.Fatalf("expected schedule to be due at grace boundary")
	}

	if ScheduleDue(nextRun, time.Date(2026, 7, 5, 17, 10, 59, 0, loc)) {
		t.Fatalf("expected schedule not to be due before scheduled minute")
	}

	if ScheduleDue(nextRun, time.Date(2026, 7, 5, 17, 12, 1, 0, loc)) {
		t.Fatalf("expected schedule not to be due after grace window")
	}
}
