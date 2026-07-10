package migration

type Phase string

const (
	PhaseIdle      Phase = "idle"
	PhaseRunning   Phase = "running"
	PhaseCompleted Phase = "completed"
	PhaseFailed    Phase = "failed"
)

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
	return Status{Phase: PhaseIdle, Step: "idle", Message: "Ready to migrate"}
}
