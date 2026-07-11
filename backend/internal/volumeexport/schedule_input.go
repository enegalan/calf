package volumeexport

import (
	"github.com/enegalan/calf/backend/internal/constants"
	"strings"
	"time"
)

// DayTimeInput is one day's export times as submitted by the API.
type DayTimeInput struct {
	Day   int      `json:"day"`
	Times []string `json:"times"`
}

// ScheduleInput is the schedule fields accepted by the volume export schedule API.
type ScheduleInput struct {
	Enabled  *bool          `json:"enabled"`
	DayTimes []DayTimeInput `json:"day_times"`
	Type     string         `json:"type"`
	FileName string         `json:"file_name"`
	Folder   string         `json:"folder"`
	ImageRef string         `json:"image_ref"`
}

// ScheduleFromInput validates and constructs a Schedule from API input, computing NextRunAt when enabled.
func ScheduleFromInput(volumeName, scheduleID string, enabled bool, input ScheduleInput) (Schedule, error) {
	exportType := strings.TrimSpace(input.Type)
	fileName := strings.TrimSpace(input.FileName)
	folder := strings.TrimSpace(input.Folder)
	imageRef := strings.TrimSpace(input.ImageRef)

	switch exportType {
	case constants.VolumeExportTypeLocalFile:
		if fileName == "" {
			fileName = DefaultFileNamePattern(volumeName)
		}
	case constants.VolumeExportTypeNewImage, constants.VolumeExportTypeRegistry:
		if imageRef == "" {
			imageRef = DefaultImageRefPattern(volumeName)
		}
	}

	schedule := Schedule{
		ID:       scheduleID,
		Volume:   volumeName,
		Enabled:  enabled,
		DayTimes: dayTimesFromInput(input),
		Type:     exportType,
		FileName: fileName,
		Folder:   folder,
		ImageRef: imageRef,
	}

	NormalizeSchedule(&schedule)

	if err := ValidateScheduleInput(schedule); err != nil {
		return Schedule{}, err
	}

	if !enabled {
		schedule.NextRunAt = ""
		return schedule, nil
	}

	nextRun, err := ComputeNextRun(schedule, time.Now())
	if err != nil {
		return Schedule{}, err
	}

	schedule.NextRunAt = nextRun.UTC().Format(time.RFC3339)
	return schedule, nil
}

// DayTimesToInput converts stored day/time schedules into API input form.
func DayTimesToInput(entries []DayTimeSchedule) []DayTimeInput {
	if len(entries) == 0 {
		return nil
	}

	payload := make([]DayTimeInput, 0, len(entries))
	for _, entry := range entries {
		payload = append(payload, DayTimeInput{
			Day:   entry.Day,
			Times: append([]string(nil), entry.Times...),
		})
	}

	return payload
}

// dayTimesFromInput converts ScheduleInput day/time entries into DayTimeSchedule values.
func dayTimesFromInput(input ScheduleInput) []DayTimeSchedule {
	if len(input.DayTimes) == 0 {
		return nil
	}

	entries := make([]DayTimeSchedule, 0, len(input.DayTimes))
	for _, entry := range input.DayTimes {
		entries = append(entries, DayTimeSchedule{
			Day:   entry.Day,
			Times: append([]string(nil), entry.Times...),
		})
	}

	return entries
}
