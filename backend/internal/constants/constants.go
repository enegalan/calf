package constants

import "time"

// Server defaults control the HTTP API listen address and polling behavior.
const (
	DefaultListenAddr     = ":8765"
	DefaultPollIntervalMS = 3000
	LogTailLineCount      = 500
)

// Host defaults apply when total memory or free disk cannot be read from the OS.
const (
	DefaultHostMemoryGB = 8
	DefaultHostDiskGB   = 500
)

// Build defaults cap persisted build history and bound build-related work.
const (
	MaxBuilds                = 200
	DefaultBuildSyncInterval = 30 * time.Second
	BuildSyncEnrichTimeout   = 2 * time.Minute
	BuildJobTimeout          = 2 * time.Hour
	MigratedBuildName        = "migrated-build"
)

// Stats history defaults control background container resource sampling.
const (
	StatsSampleInterval   = 5 * time.Second
	StatsHistoryRetention = 15 * time.Minute
)

// Resource Saver defaults control idle engine shutdown when no containers run.
const (
	ResourceSaverPollInterval   = 5 * time.Second
	ResourceSaverTimeoutMinSec  = 30
	ResourceSaverTimeoutMaxSec  = 3600
	DefaultResourceSaverTimeout = 300
)

// Troubleshoot defaults bound destructive cleanup (guest disk delete can be slow).
const (
	TroubleshootActionTimeout = 5 * time.Minute
)

// Command defaults apply to shell-outs and other retried runtime operations.
const (
	DefaultActionTimeout     = 30 * time.Second
	DefaultCommandRetries    = 4
	DefaultCommandRetryDelay = 200 * time.Millisecond
)

// Runtime defaults configure the VM name, nerdctl path, and exec terminal.
const (
	DefaultVMName   = "calf"
	NerdctlBin      = "/usr/local/bin/nerdctl"
	DefaultExecTerm = "xterm-256color"
	// DockerAPIReadyPollBase is the initial delay between Docker API readiness checks during VM boot.
	DockerAPIReadyPollBase = 200 * time.Millisecond
	// DockerAPIReadyPollMax caps exponential backoff while waiting for the Docker HTTP API.
	DockerAPIReadyPollMax = 2 * time.Second
)

// RuntimeMode values identify whether Calf runs containers in a VM guest or on the host.
const (
	RuntimeModeVM     = "vm"
	RuntimeModeNative = "native"
)

// RuntimeState values describe whether the container runtime is up, down, or unknown.
const (
	RuntimeStateRunning = "running"
	RuntimeStateStopped = "stopped"
	RuntimeStateUnknown = "unknown"
)

// Docker CLI defaults control context naming and CLI operation timeouts.
const (
	DockerContextName            = "calf"
	DockerCLITimeout             = 2 * time.Minute
	DockerContextManagerInterval = 5 * time.Second
)

// Compose labels are container labels used to infer compose project metadata.
const (
	ComposeProjectLabel     = "com.docker.compose.project"
	ComposeServiceLabel     = "com.docker.compose.service"
	ComposeWorkingDirLabel  = "com.docker.compose.project.working_dir"
	ComposeConfigFilesLabel = "com.docker.compose.project.config_files"
)

// ComposeStageSkipDirs are top-level directory names excluded when staging compose project files for migration.
var ComposeStageSkipDirs = map[string]struct{}{
	".git":         {},
	"node_modules": {},
	"vendor":       {},
	".next":        {},
	"dist":         {},
	"build":        {},
	"__pycache__":  {},
}

// Network defaults apply when nerdctl does not report a network scope.
const DefaultNetworkScope = "local"

// AlpineSmokeImage is the reference image used for lightweight runtime smoke checks.
const AlpineSmokeImage = "alpine:3.20"

// GitHubRepo is the canonical Calf repository used for releases and guest-disk downloads.
const GitHubRepo = "enegalan/calf"

// Guest disk release asset name prefixes (arch suffix added at runtime).
const (
	GuestDiskAssetPrefix = "calf-guest-disk"
	GuestEFIAssetPrefix  = "calf-guest-efi"
)

// JobStatus values are persisted statuses for builds, volume exports, and similar jobs.
const (
	JobStatusRunning   = "running"
	JobStatusCompleted = "completed"
	JobStatusFailed    = "failed"
)

// VolumeExportType values identify how a volume export is packaged and delivered.
const (
	VolumeExportTypeLocalFile  = "local_file"
	VolumeExportTypeLocalImage = "local_image"
	VolumeExportTypeNewImage   = "new_image"
	VolumeExportTypeRegistry   = "registry"
)

// Volume export scheduling keeps a one-minute grace window aligned with the scheduler tick
// so a once-per-minute poll cannot miss a scheduled export slot.
const (
	ScheduleRunGrace        = time.Minute
	ExportSchedulerInterval = ScheduleRunGrace
	VolumeExportTimeout     = 30 * time.Minute
)

// LogsWebSocket defaults control ping/pong keep-alive and write deadlines for log streams.
const (
	LogsPongWait       = 60 * time.Second
	LogsPingPeriod     = (LogsPongWait * 9) / 10
	LogsWriteWait      = 10 * time.Second
	LogStreamRetryBase = 500 * time.Millisecond
	LogStreamRetryMax  = 5 * time.Second
)

// Byte unit conversions used for disk-space checks and human-readable size formatting.
const (
	BytesPerKiB = 1024
	BytesPerMiB = 1024 * 1024
	BytesPerGiB = 1024 * 1024 * 1024
)

// Docker byte unit conversions match decimal (1000-based) sizes from docker system df.
const (
	DockerBytesPerKB = 1000
	DockerBytesPerMB = 1000 * DockerBytesPerKB
	DockerBytesPerGB = 1000 * DockerBytesPerMB
)

// MigrationPhase values track Docker Desktop migration progress in the API.
const (
	MigrationPhaseIdle      = "idle"
	MigrationPhaseRunning   = "running"
	MigrationPhaseCompleted = "completed"
	MigrationPhaseFailed    = "failed"
)

// MigrationHeadroomBytes is extra disk space reserved beyond the estimated Docker Desktop migration size.
const MigrationHeadroomBytes = 2 * BytesPerGiB

// Registry defaults identify Docker Hub in config.json and OAuth device-flow requests.
const (
	DefaultRegistryServer   = "docker.io"
	DockerHubOAuthTenantURL = "https://login.docker.com"
	DockerHubOAuthAudience  = "https://hub.docker.com"
	DockerHubOAuthClientID  = "L4v0dmlNBpYUjGGab0C2JtgTgXr1Qz4d"
)

// DockerHubRegistryKeys are config.json auths keys that identify Docker Hub credentials.
var DockerHubRegistryKeys = []string{
	"https://index.docker.io/v1/",
	"index.docker.io",
	"docker.io",
	"registry-1.docker.io",
	"https://registry-1.docker.io/v2/",
}
