package migration

import "github.com/enegalan/calf/backend/internal/constants"

// Phase represents the current phase of the migration.
type Phase string

// Summary represents the summary of the migration.
type Summary struct {
	ConfigApplied   bool `json:"config_applied"`
	ImagesTotal     int  `json:"images_total"`
	ImagesOK        int  `json:"images_ok"`
	VolumesTotal    int  `json:"volumes_total"`
	VolumesOK       int  `json:"volumes_ok"`
	ContainersTotal int  `json:"containers_total"`
	ContainersOK    int  `json:"containers_ok"`
	BuildsTotal     int  `json:"builds_total"`
	BuildsOK        int  `json:"builds_ok"`
}

// Status represents the current status of the migration.
type Status struct {
	Phase    Phase   `json:"phase"`
	Step     string  `json:"step"`
	Progress int     `json:"progress"`
	Message  string  `json:"message"`
	Error    string  `json:"error,omitempty"`
	Summary  Summary `json:"summary"`
}

// IdleStatus returns the default migration status shown before a run starts.
func IdleStatus() Status {
	return Status{Phase: Phase(constants.MigrationPhaseIdle), Step: "idle", Message: "Ready to migrate"}
}
