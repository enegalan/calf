package volumeexport

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/constants"
)

// NormalizeSchedule sorts day entries and times within each day for stable storage and comparison.
func NormalizeSchedule(schedule *Schedule) {
	if len(schedule.DayTimes) == 0 {
		return
	}

	sort.Slice(schedule.DayTimes, func(i, j int) bool {
		return schedule.DayTimes[i].Day < schedule.DayTimes[j].Day
	})

	for index := range schedule.DayTimes {
		sort.Strings(schedule.DayTimes[index].Times)
	}
}

// ValidateScheduleInput checks that an enabled schedule has valid days, times, and export targets.
func ValidateScheduleInput(schedule Schedule) error {
	NormalizeSchedule(&schedule)

	if !schedule.Enabled {
		return nil
	}

	if len(schedule.DayTimes) == 0 {
		return fmt.Errorf("at least one day with export times is required")
	}

	for _, entry := range schedule.DayTimes {
		if entry.Day < 0 || entry.Day > 6 {
			return fmt.Errorf("day values must be between 0 (Sunday) and 6 (Saturday)")
		}

		if len(entry.Times) == 0 {
			return fmt.Errorf("day %d requires at least one export time", entry.Day)
		}

		seenTimes := make(map[string]struct{}, len(entry.Times))
		for _, value := range entry.Times {
			if _, _, err := parseTimeOfDay(value); err != nil {
				return err
			}

			key := strings.TrimSpace(value)
			if _, ok := seenTimes[key]; ok {
				return fmt.Errorf("duplicate export time %q on day %d", key, entry.Day)
			}

			seenTimes[key] = struct{}{}
		}
	}

	exportType := strings.TrimSpace(schedule.Type)
	if exportType != constants.VolumeExportTypeLocalFile && exportType != constants.VolumeExportTypeLocalImage && exportType != constants.VolumeExportTypeNewImage && exportType != constants.VolumeExportTypeRegistry {
		return fmt.Errorf("unsupported export type %q", exportType)
	}

	if exportType == constants.VolumeExportTypeLocalFile {
		if strings.TrimSpace(schedule.Folder) == "" {
			return fmt.Errorf("folder is required")
		}
	} else if strings.TrimSpace(schedule.ImageRef) == "" {
		return fmt.Errorf("image_ref is required")
	}

	return nil
}

// ComputeNextRun returns the earliest upcoming run time, including the current minute when still within grace.
func ComputeNextRun(schedule Schedule, now time.Time) (time.Time, error) {
	return computeNextRun(schedule, now, false)
}

// ComputeNextRunAfterRun returns the next run strictly after now, used after a schedule has just fired.
func ComputeNextRunAfterRun(schedule Schedule, now time.Time) (time.Time, error) {
	return computeNextRun(schedule, now, true)
}

// ScheduleDue reports whether a scheduled export should run on this tick.
// The run window spans the scheduled minute plus ScheduleRunGrace so a once-per-minute scheduler cannot skip a slot.
func ScheduleDue(nextRunAt string, now time.Time) bool {
	if strings.TrimSpace(nextRunAt) == "" {
		return false
	}

	nextRun, err := time.Parse(time.RFC3339, nextRunAt)
	if err != nil {
		return false
	}

	startMinute := nextRun.Truncate(time.Minute)
	nowMinute := now.Truncate(time.Minute)
	if nowMinute.Before(startMinute) {
		return false
	}

	return slotStillRunnable(nextRun, now)
}

// slotStillRunnable reports whether now is still within the grace window after candidate.
func slotStillRunnable(candidate, now time.Time) bool {
	return !now.After(candidate.Add(constants.ScheduleRunGrace))
}

// computeNextRun scans up to 14 days ahead for the earliest matching slot.
// afterRun skips slots at or before now; the initial schedule uses slotStillRunnable so a missed minute can still run within grace.
func computeNextRun(schedule Schedule, now time.Time, afterRun bool) (time.Time, error) {
	NormalizeSchedule(&schedule)

	if !schedule.Enabled {
		return time.Time{}, nil
	}

	if err := ValidateScheduleInput(schedule); err != nil {
		return time.Time{}, err
	}

	loc := now.Location()
	var next time.Time

	for offset := 0; offset < 14; offset++ {
		candidateDate := now.AddDate(0, 0, offset)
		dayOfWeek := int(candidateDate.Weekday())
		times := timesForDay(schedule.DayTimes, dayOfWeek)
		if len(times) == 0 {
			continue
		}

		for _, timeValue := range times {
			hour, minute, err := parseTimeOfDay(timeValue)
			if err != nil {
				return time.Time{}, err
			}

			candidate := time.Date(
				candidateDate.Year(),
				candidateDate.Month(),
				candidateDate.Day(),
				hour,
				minute,
				0,
				0,
				loc,
			)
			if afterRun {
				if !candidate.After(now) {
					continue
				}
			} else if !slotStillRunnable(candidate, now) {
				continue
			}

			if next.IsZero() || candidate.Before(next) {
				next = candidate
			}
		}
	}

	if next.IsZero() {
		return time.Time{}, fmt.Errorf("no upcoming run found for schedule")
	}

	return next, nil
}

// parseTimeOfDay parses an HH:MM export time string.
func parseTimeOfDay(value string) (hour int, minute int, err error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0, 0, fmt.Errorf("export time is required")
	}

	parsed, err := time.Parse("15:04", value)
	if err != nil {
		return 0, 0, fmt.Errorf("export times must use HH:MM format")
	}

	return parsed.Hour(), parsed.Minute(), nil
}

// timesForDay returns the configured export times for the given weekday, or nil when none are set.
func timesForDay(dayTimes []DayTimeSchedule, day int) []string {
	for _, entry := range dayTimes {
		if entry.Day == day {
			return entry.Times
		}
	}

	return nil
}
