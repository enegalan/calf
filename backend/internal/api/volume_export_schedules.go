package api

import (
	"net/http"
	"strings"
	"time"

	"github.com/enegalan/calf/backend/internal/volumeexport"
)

type dayTimePayload struct {
	Day   int      `json:"day"`
	Times []string `json:"times"`
}

type schedulePayload struct {
	Enabled    *bool            `json:"enabled"`
	DayTimes   []dayTimePayload   `json:"day_times"`
	DaysOfWeek []int              `json:"days_of_week"`
	Times      []string           `json:"times"`
	Type       string             `json:"type"`
	FileName   string             `json:"file_name"`
	Folder     string             `json:"folder"`
	ImageRef   string             `json:"image_ref"`
}

func (s *Server) volumeScheduleStore() (*volumeexport.ScheduleStore, error) {
	return volumeexport.NewScheduleStore()
}

func (s *Server) handleVolumeExportSchedules(w http.ResponseWriter, r *http.Request, volumeName string) {
	switch r.Method {
	case http.MethodGet:
		s.handleVolumeExportSchedulesList(w, r, volumeName)
	case http.MethodPost:
		s.handleVolumeExportScheduleCreate(w, r, volumeName)
	default:
		methodNotAllowed(w, r)
	}
}

func (s *Server) handleVolumeExportSchedulesList(w http.ResponseWriter, r *http.Request, volumeName string) {
	store, err := s.volumeScheduleStore()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	schedules, err := store.List(volumeName)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, schedules)
}

func (s *Server) handleVolumeExportScheduleCreate(w http.ResponseWriter, r *http.Request, volumeName string) {
	var payload schedulePayload

	if err := jsonDecode(r, &payload); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	enabled := false
	if payload.Enabled != nil {
		enabled = *payload.Enabled
	}

	schedule, err := s.buildScheduleFromPayload(volumeName, "", enabled, payload)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	store, err := s.volumeScheduleStore()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	schedule.ID = store.NewID(volumeName)
	schedule.CreatedAt = time.Now().UTC().Format(time.RFC3339)

	if err := store.Save(schedule); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, schedule)
}

func (s *Server) handleVolumeExportScheduleItem(w http.ResponseWriter, r *http.Request, volumeName, scheduleID string) {
	switch r.Method {
	case http.MethodPut:
		s.handleVolumeExportScheduleUpdate(w, r, volumeName, scheduleID)
	case http.MethodDelete:
		s.handleVolumeExportScheduleDelete(w, r, volumeName, scheduleID)
	default:
		methodNotAllowed(w, r)
	}
}

func (s *Server) handleVolumeExportScheduleUpdate(w http.ResponseWriter, r *http.Request, volumeName, scheduleID string) {
	store, err := s.volumeScheduleStore()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	existing, err := store.Get(volumeName, scheduleID)
	if err != nil {
		writeError(w, http.StatusNotFound, "schedule not found")
		return
	}

	var payload schedulePayload

	if err := jsonDecode(r, &payload); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	enabled := existing.Enabled
	if payload.Enabled != nil {
		enabled = *payload.Enabled
	}

	volumeexport.NormalizeSchedule(&existing)

	merged := schedulePayload{
		Enabled:    &enabled,
		DayTimes:   dayTimesToPayload(existing.DayTimes),
		DaysOfWeek: append([]int(nil), existing.DaysOfWeek...),
		Times:      append([]string(nil), existing.Times...),
		Type:       existing.Type,
		FileName:   existing.FileName,
		Folder:     existing.Folder,
		ImageRef:   existing.ImageRef,
	}

	if len(payload.DayTimes) > 0 {
		merged.DayTimes = payload.DayTimes
		merged.DaysOfWeek = nil
		merged.Times = nil
	}

	if len(payload.DaysOfWeek) > 0 {
		merged.DaysOfWeek = payload.DaysOfWeek
	}

	if len(payload.Times) > 0 {
		merged.Times = payload.Times
	}

	if payload.Type != "" {
		merged.Type = payload.Type
	}

	if payload.FileName != "" {
		merged.FileName = payload.FileName
	}

	if payload.Folder != "" {
		merged.Folder = payload.Folder
	}

	if payload.ImageRef != "" {
		merged.ImageRef = payload.ImageRef
	}

	schedule, err := s.buildScheduleFromPayload(volumeName, scheduleID, enabled, merged)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	schedule.ID = scheduleID
	schedule.CreatedAt = existing.CreatedAt
	schedule.LastRunAt = existing.LastRunAt
	schedule.LastStatus = existing.LastStatus
	schedule.LastError = existing.LastError

	if err := store.Save(schedule); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, schedule)
}

func (s *Server) handleVolumeExportScheduleDelete(w http.ResponseWriter, r *http.Request, volumeName, scheduleID string) {
	store, err := s.volumeScheduleStore()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	if err := store.Delete(volumeName, scheduleID); err != nil {
		writeError(w, http.StatusNotFound, "schedule not found")
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) buildScheduleFromPayload(
	volumeName, scheduleID string,
	enabled bool,
	payload schedulePayload,
) (volumeexport.Schedule, error) {
	exportType := strings.TrimSpace(payload.Type)
	fileName := strings.TrimSpace(payload.FileName)
	folder := strings.TrimSpace(payload.Folder)
	imageRef := strings.TrimSpace(payload.ImageRef)

	if exportType == volumeexport.TypeLocalFile {
		if fileName == "" {
			fileName = volumeexport.DefaultFileNamePattern(volumeName)
		}
	} else if exportType == volumeexport.TypeNewImage || exportType == volumeexport.TypeRegistry {
		if imageRef == "" {
			imageRef = volumeexport.DefaultImageRefPattern(volumeName)
		}
	}

	schedule := volumeexport.Schedule{
		ID:         scheduleID,
		Volume:     volumeName,
		Enabled:    enabled,
		DayTimes:   dayTimesFromPayload(payload),
		DaysOfWeek: append([]int(nil), payload.DaysOfWeek...),
		Times:      append([]string(nil), payload.Times...),
		Type:       exportType,
		FileName:   fileName,
		Folder:     folder,
		ImageRef:   imageRef,
	}

	volumeexport.NormalizeSchedule(&schedule)

	if err := volumeexport.ValidateScheduleInput(schedule); err != nil {
		return volumeexport.Schedule{}, err
	}

	if !enabled {
		schedule.NextRunAt = ""
		return schedule, nil
	}

	nextRun, err := volumeexport.ComputeNextRun(schedule, time.Now())
	if err != nil {
		return volumeexport.Schedule{}, err
	}

	schedule.NextRunAt = nextRun.UTC().Format(time.RFC3339)
	return schedule, nil
}

func dayTimesFromPayload(payload schedulePayload) []volumeexport.DayTimeSchedule {
	if len(payload.DayTimes) == 0 {
		return nil
	}

	entries := make([]volumeexport.DayTimeSchedule, 0, len(payload.DayTimes))
	for _, entry := range payload.DayTimes {
		entries = append(entries, volumeexport.DayTimeSchedule{
			Day:   entry.Day,
			Times: append([]string(nil), entry.Times...),
		})
	}

	return entries
}

func dayTimesToPayload(entries []volumeexport.DayTimeSchedule) []dayTimePayload {
	if len(entries) == 0 {
		return nil
	}

	payload := make([]dayTimePayload, 0, len(entries))
	for _, entry := range entries {
		payload = append(payload, dayTimePayload{
			Day:   entry.Day,
			Times: append([]string(nil), entry.Times...),
		})
	}

	return payload
}
