package runtime

// BuildStep represents a step in a build.
type BuildStep struct {
	Index      int    `json:"index"`
	Total      int    `json:"total"`
	Name       string `json:"name"`
	Cached     bool   `json:"cached"`
	DurationMs int64  `json:"duration_ms"`
	Log        string `json:"log,omitempty"`
}

// BuildDependency represents a dependency in a build.
type BuildDependency struct {
	Source   string `json:"source"`
	Platform string `json:"platform"`
	Digest   string `json:"digest"`
}

// BuildArtifact represents an artifact in a build.
type BuildArtifact struct {
	Name     string `json:"name"`
	Platform string `json:"platform"`
	Digest   string `json:"digest"`
	Size     string `json:"size"`
}

// BuildTag represents a tag in a build.
type BuildTag struct {
	Tag    string `json:"tag"`
	Digest string `json:"digest"`
}

// BuildTiming represents the timing of a build.
type BuildTiming struct {
	ImagePullsMs     int64 `json:"image_pulls_ms"`
	LocalTransfersMs int64 `json:"local_transfers_ms"`
	ExecutionsMs     int64 `json:"executions_ms"`
	FileOperationsMs int64 `json:"file_operations_ms"`
	ResultExportsMs  int64 `json:"result_exports_ms"`
	IdleMs           int64 `json:"idle_ms"`
}

// Build represents a build.
type Build struct {
	ID             string            `json:"id"`
	HistoryRef     string            `json:"history_ref,omitempty"`
	Tag            string            `json:"tag"`
	Context        string            `json:"context"`
	Dockerfile     string            `json:"dockerfile"`
	Platform       string            `json:"platform"`
	Status         string            `json:"status"`
	CreatedAt      string            `json:"created_at"`
	FinishedAt     string            `json:"finished_at,omitempty"`
	DurationMs     int64             `json:"duration_ms"`
	Error          string            `json:"error,omitempty"`
	Builder        string            `json:"builder"`
	CachedSteps    int               `json:"cached_steps"`
	TotalSteps     int               `json:"total_steps"`
	Steps          []BuildStep       `json:"steps"`
	Dependencies   []BuildDependency `json:"dependencies"`
	Results        []BuildArtifact   `json:"results"`
	Tags           []BuildTag        `json:"tags"`
	Timing         BuildTiming       `json:"timing"`
	SourceRevision string            `json:"source_revision,omitempty"`
	RemoteSource   string            `json:"remote_source,omitempty"`
	RawLog         string            `json:"raw_log,omitempty"`
}

// BuildResult represents the result of a build.
type BuildResult struct {
	RawLog       string
	Steps        []BuildStep
	Timing       BuildTiming
	CachedSteps  int
	TotalSteps   int
	Dependencies []BuildDependency
	Results      []BuildArtifact
	Tags         []BuildTag
}

// BuildSource represents the source of a build.
type BuildSource struct {
	Path     string `json:"path"`
	Filename string `json:"filename"`
	Content  string `json:"content"`
	Platform string `json:"platform"`
}
