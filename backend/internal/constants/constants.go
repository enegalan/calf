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
