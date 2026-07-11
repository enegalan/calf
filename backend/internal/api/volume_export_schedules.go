package api

import (
	"net/http"
	"time"

	"github.com/enegalan/calf/backend/internal/httpkit"
	"github.com/enegalan/calf/backend/internal/utils"
	"github.com/enegalan/calf/backend/internal/volumeexport"
)

// handleVolumeExportSchedules routes GET and POST /v1/volumes/{name}/export-schedules.
func (g *Gateway) handleVolumeExportSchedules(w http.ResponseWriter, r *http.Request, volumeName string) {
	switch r.Method {
	case http.MethodGet:
		g.handleVolumeExportSchedulesList(w, r, volumeName)
	case http.MethodPost:
		g.handleVolumeExportScheduleCreate(w, r, volumeName)
	default:
		httpkit.MethodNotAllowed(w, r)
	}
}

// handleVolumeExportSchedulesList serves GET /v1/volumes/{name}/export-schedules.
func (g *Gateway) handleVolumeExportSchedulesList(w http.ResponseWriter, r *http.Request, volumeName string) {
	store, err := volumeexport.NewScheduleStore()
	if err != nil {
		g.writeVolumeStoreError(w, "failed to open schedule store", err)
		return
	}

	schedules, err := store.List(volumeName)
	if err != nil {
		g.writeVolumeStoreError(w, "failed to list export schedules", err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, schedules)
}

// handleVolumeExportScheduleCreate serves POST /v1/volumes/{name}/export-schedules.
func (g *Gateway) handleVolumeExportScheduleCreate(w http.ResponseWriter, r *http.Request, volumeName string) {
	var payload volumeexport.ScheduleInput

	if err := httpkit.JSONDecode(r, &payload); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	enabled := false
	if payload.Enabled != nil {
		enabled = *payload.Enabled
	}

	schedule, err := volumeexport.ScheduleFromInput(volumeName, "", enabled, payload)
	if err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	store, err := volumeexport.NewScheduleStore()
	if err != nil {
		g.writeVolumeStoreError(w, "failed to open schedule store", err)
		return
	}

	schedule.ID = store.NewID(volumeName)
	schedule.CreatedAt = time.Now().UTC().Format(time.RFC3339)

	if err := store.Save(schedule); err != nil {
		g.writeVolumeStoreError(w, "failed to save export schedule", err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, schedule)
}

// handleVolumeExportScheduleItem routes PUT and DELETE for a single export schedule.
func (g *Gateway) handleVolumeExportScheduleItem(w http.ResponseWriter, r *http.Request, volumeName, scheduleID string) {
	switch r.Method {
	case http.MethodPut:
		g.handleVolumeExportScheduleUpdate(w, r, volumeName, scheduleID)
	case http.MethodDelete:
		g.handleVolumeExportScheduleDelete(w, r, volumeName, scheduleID)
	default:
		httpkit.MethodNotAllowed(w, r)
	}
}

// handleVolumeExportScheduleUpdate serves PUT /v1/volumes/{name}/export-schedules/{id}.
func (g *Gateway) handleVolumeExportScheduleUpdate(w http.ResponseWriter, r *http.Request, volumeName, scheduleID string) {
	store, err := volumeexport.NewScheduleStore()
	if err != nil {
		g.writeVolumeStoreError(w, "failed to open schedule store", err)
		return
	}

	existing, err := store.Get(volumeName, scheduleID)
	if err != nil {
		httpkit.WriteError(w, http.StatusNotFound, "schedule not found")
		return
	}

	var payload volumeexport.ScheduleInput

	if err := httpkit.JSONDecode(r, &payload); err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	enabled := existing.Enabled
	if payload.Enabled != nil {
		enabled = *payload.Enabled
	}

	volumeexport.NormalizeSchedule(&existing)

	merged := volumeexport.ScheduleInput{
		Enabled:  &enabled,
		DayTimes: volumeexport.DayTimesToInput(existing.DayTimes),
		Type:     existing.Type,
		FileName: existing.FileName,
		Folder:   existing.Folder,
		ImageRef: existing.ImageRef,
	}

	if len(payload.DayTimes) > 0 {
		merged.DayTimes = payload.DayTimes
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

	schedule, err := volumeexport.ScheduleFromInput(volumeName, scheduleID, enabled, merged)
	if err != nil {
		httpkit.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	schedule.ID = scheduleID
	schedule.CreatedAt = existing.CreatedAt
	schedule.LastRunAt = existing.LastRunAt
	schedule.LastStatus = existing.LastStatus
	schedule.LastError = existing.LastError

	if err := store.Save(schedule); err != nil {
		g.writeVolumeStoreError(w, "failed to save export schedule", err)
		return
	}

	httpkit.WriteJSON(w, http.StatusOK, schedule)
}

// handleVolumeExportScheduleDelete serves DELETE /v1/volumes/{name}/export-schedules/{id}.
func (g *Gateway) handleVolumeExportScheduleDelete(w http.ResponseWriter, r *http.Request, volumeName, scheduleID string) {
	store, err := volumeexport.NewScheduleStore()
	if err != nil {
		g.writeVolumeStoreError(w, "failed to open schedule store", err)
		return
	}

	if err := store.Delete(volumeName, scheduleID); err != nil {
		httpkit.WriteError(w, http.StatusNotFound, "schedule not found")
		return
	}

	utils.WriteOK(w)
}
