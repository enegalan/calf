package constants

import "time"

const (
	DefaultListenAddr     = ":8765"
	DefaultPollIntervalMS = 3000
	LogTailLineCount      = 500
	AlpineSmokeImage      = "alpine:3.20"
)

const DefaultActionTimeout = 30 * time.Second
const DefaultBuildSyncInterval = 30 * time.Second
const BuildSyncEnrichTimeout = 2 * time.Minute
const BuildJobTimeout = 2 * time.Hour
const DockerContextManagerInterval = 5 * time.Second

const LogsPongWait = 60 * time.Second
const LogsPingPeriod = (LogsPongWait * 9) / 10
const LogsWriteWait = 10 * time.Second
const VolumeExportTimeout = 30 * time.Minute
// ExportSchedulerInterval must match volumeexport.ScheduleRunGrace so a once-per-minute tick cannot miss a scheduled export slot.
const ExportSchedulerInterval = time.Minute
