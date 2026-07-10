package api

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/enegalan/calf/backend/internal/runtime"
	"github.com/enegalan/calf/backend/internal/volumeexport"
)

// exportSchedulerInterval must match volumeexport.ScheduleRunGrace so a
// once-per-minute tick cannot miss a scheduled export slot.
const exportSchedulerInterval = time.Minute

type exportScheduler struct {
	server    *Server
	logger    *slog.Logger
	ctx       context.Context
	cancel    context.CancelFunc
	stop      chan struct{}
	done      chan struct{}
	startOnce sync.Once
	stopOnce  sync.Once
}

// newExportScheduler creates a background scheduler bound to server for recurring volume exports.
func newExportScheduler(server *Server, logger *slog.Logger) *exportScheduler {
	ctx, cancel := context.WithCancel(context.Background())
	return &exportScheduler{
		server: server,
		logger: logger,
		ctx:    ctx,
		cancel: cancel,
		stop:   make(chan struct{}),
		done:   make(chan struct{}),
	}
}

// Start launches the export scheduler goroutine exactly once.
func (s *exportScheduler) Start() {
	s.startOnce.Do(func() {
		go s.run()
	})
}

// Stop cancels the scheduler and waits for its goroutine to exit.
func (s *exportScheduler) Stop() {
	s.stopOnce.Do(func() {
		s.cancel()
		close(s.stop)
		<-s.done
	})
}

// run ticks once per minute, checking for due export schedules until stopped.
func (s *exportScheduler) run() {
	defer close(s.done)

	ticker := time.NewTicker(exportSchedulerInterval)
	defer ticker.Stop()

	s.tick()

	for {
		select {
		case <-ticker.C:
			s.tick()
		case <-s.stop:
			return
		}
	}
}

// tick evaluates all enabled schedules and runs any that are due.
func (s *exportScheduler) tick() {
	store, err := volumeexport.NewScheduleStore()
	if err != nil {
		s.logger.Error("volume export scheduler failed to open schedule store", "error", err)
		return
	}

	schedules, err := store.ListAll()
	if err != nil {
		s.logger.Warn("volume export scheduler skipped unreadable schedule files", "error", err)
	}
	if len(schedules) == 0 {
		return
	}

	now := time.Now()
	for _, schedule := range schedules {
		select {
		case <-s.stop:
			return
		default:
		}

		if !schedule.Enabled {
			continue
		}

		if !volumeexport.ScheduleDue(schedule.NextRunAt, now) {
			continue
		}

		s.logger.Info(
			"running scheduled volume export",
			"volume", schedule.Volume,
			"schedule", schedule.ID,
			"next_run_at", schedule.NextRunAt,
		)
		s.runSchedule(store, schedule, now)
	}
}

// runSchedule executes one scheduled export and updates last-run metadata and next run time.
func (s *exportScheduler) runSchedule(store *volumeexport.ScheduleStore, schedule volumeexport.Schedule, tickNow time.Time) {
	ctx, cancel := context.WithTimeout(s.ctx, 30*time.Minute)
	defer cancel()

	status, err := s.server.runtime.Status(ctx)
	if err != nil || status.State != runtime.StateRunning {
		schedule.LastStatus = volumeexport.StatusFailed
		schedule.LastError = "runtime is not running"
		schedule.LastRunAt = tickNow.UTC().Format(time.RFC3339)
		if nextRun, nextErr := volumeexport.ComputeNextRunAfterRun(schedule, time.Now()); nextErr == nil {
			schedule.NextRunAt = nextRun.UTC().Format(time.RFC3339)
		}
		if saveErr := store.Save(schedule); saveErr != nil {
			s.logger.Error("volume export scheduler failed to save skipped schedule", "schedule", schedule.ID, "error", saveErr)
		}
		return
	}

	request := volumeExportRequest{
		Type: schedule.Type,
	}

	fileName, imageRef := volumeexport.ResolveScheduledExportNames(schedule, tickNow)
	request.FileName = fileName
	request.ImageRef = imageRef
	request.Folder = schedule.Folder

	_, exportErr := s.server.executeVolumeExport(ctx, schedule.Volume, request)
	schedule.LastRunAt = tickNow.UTC().Format(time.RFC3339)

	if exportErr != nil {
		schedule.LastStatus = volumeexport.StatusFailed
		schedule.LastError = exportErr.Error()
		s.logger.Error(
			"scheduled volume export failed",
			"volume", schedule.Volume,
			"schedule", schedule.ID,
			"error", exportErr,
		)
	} else {
		schedule.LastStatus = volumeexport.StatusCompleted
		schedule.LastError = ""
		s.logger.Info("scheduled volume export completed", "volume", schedule.Volume, "schedule", schedule.ID)
	}

	nextRun, err := volumeexport.ComputeNextRunAfterRun(schedule, time.Now())
	if err != nil {
		schedule.Enabled = false
		schedule.LastStatus = volumeexport.StatusFailed
		schedule.LastError = err.Error()
	} else {
		schedule.NextRunAt = nextRun.UTC().Format(time.RFC3339)
	}

	if err := store.Save(schedule); err != nil {
		s.logger.Error("volume export scheduler failed to save schedule", "schedule", schedule.ID, "error", err)
	}
}
