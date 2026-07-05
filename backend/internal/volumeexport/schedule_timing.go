package volumeexport

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

func NormalizeSchedule(schedule *Schedule) {
	if len(schedule.DayTimes) == 0 && len(schedule.DaysOfWeek) > 0 && len(schedule.Times) > 0 {
		schedule.DayTimes = make([]DayTimeSchedule, 0, len(schedule.DaysOfWeek))
		for _, day := range schedule.DaysOfWeek {
			times := append([]string(nil), schedule.Times...)
			sort.Strings(times)
			schedule.DayTimes = append(schedule.DayTimes, DayTimeSchedule{
				Day:   day,
				Times: times,
			})
		}
	}

	if len(schedule.DayTimes) == 0 {
		times := make([]string, 0, 1)
		if strings.TrimSpace(schedule.TimeOfDay) != "" {
			times = append(times, strings.TrimSpace(schedule.TimeOfDay))
		}

		days := make([]int, 0)
		switch strings.TrimSpace(schedule.Frequency) {
		case FrequencyWeekly:
			days = append(days, schedule.DayOfWeek)
		case FrequencyMonthly:
			// Legacy monthly schedules have no cron equivalent; leave days empty.
		default:
			days = []int{0, 1, 2, 3, 4, 5, 6}
		}

		if len(days) > 0 && len(times) > 0 {
			schedule.DayTimes = make([]DayTimeSchedule, 0, len(days))
			for _, day := range days {
				dayTimes := append([]string(nil), times...)
				sort.Strings(dayTimes)
				schedule.DayTimes = append(schedule.DayTimes, DayTimeSchedule{
					Day:   day,
					Times: dayTimes,
				})
			}
		}
	}

	if len(schedule.DayTimes) > 0 {
		sort.Slice(schedule.DayTimes, func(i, j int) bool {
			return schedule.DayTimes[i].Day < schedule.DayTimes[j].Day
		})

		for index := range schedule.DayTimes {
			sort.Strings(schedule.DayTimes[index].Times)
		}

		schedule.DaysOfWeek = uniqueDaysFromDayTimes(schedule.DayTimes)
		schedule.Times = unionTimesFromDayTimes(schedule.DayTimes)
	}
}

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
	if exportType != TypeLocalFile && exportType != TypeLocalImage && exportType != TypeNewImage && exportType != TypeRegistry {
		return fmt.Errorf("unsupported export type %q", exportType)
	}

	if exportType == TypeLocalFile {
		if strings.TrimSpace(schedule.Folder) == "" {
			return fmt.Errorf("folder is required")
		}
	} else if strings.TrimSpace(schedule.ImageRef) == "" {
		return fmt.Errorf("image_ref is required")
	}

	return nil
}

func ComputeNextRun(schedule Schedule, now time.Time) (time.Time, error) {
	return computeNextRun(schedule, now, false)
}

func ComputeNextRunAfterRun(schedule Schedule, now time.Time) (time.Time, error) {
	return computeNextRun(schedule, now, true)
}

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

func slotStillRunnable(candidate, now time.Time) bool {
	return !now.After(candidate.Add(ScheduleRunGrace))
}

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

func timesForDay(dayTimes []DayTimeSchedule, day int) []string {
	for _, entry := range dayTimes {
		if entry.Day == day {
			return entry.Times
		}
	}

	return nil
}

func uniqueDaysFromDayTimes(dayTimes []DayTimeSchedule) []int {
	days := make([]int, 0, len(dayTimes))
	for _, entry := range dayTimes {
		days = append(days, entry.Day)
	}

	sort.Ints(days)

	unique := make([]int, 0, len(days))
	for _, day := range days {
		if len(unique) == 0 || unique[len(unique)-1] != day {
			unique = append(unique, day)
		}
	}

	return unique
}

func unionTimesFromDayTimes(dayTimes []DayTimeSchedule) []string {
	seen := make(map[string]struct{})
	times := make([]string, 0)
	for _, entry := range dayTimes {
		for _, value := range entry.Times {
			key := strings.TrimSpace(value)
			if key == "" {
				continue
			}

			if _, ok := seen[key]; ok {
				continue
			}

			seen[key] = struct{}{}
			times = append(times, key)
		}
	}

	sort.Strings(times)
	return times
}
