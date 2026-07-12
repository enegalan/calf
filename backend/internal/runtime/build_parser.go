package runtime

import (
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Regular expressions for parsing build log lines into steps and timing buckets.
var (
	buildStepHeaderRe = regexp.MustCompile(`^#(\d+)\s+(\[[^\]]+\]\s+)?(.+)$`)
	buildStepDoneRe   = regexp.MustCompile(`^#(\d+)\s+DONE\s+([\d.]+)s`)
	buildStepCachedRe = regexp.MustCompile(`^#(\d+)\s+CACHED`)
	buildStepIndexRe  = regexp.MustCompile(`^#(\d+)\s+\[(\d+)/(\d+)\]`)
)

// ParseBuildOutput parses nerdctl/docker build log output into structured steps and timing buckets.
func ParseBuildOutput(output string) BuildResult {
	result := BuildResult{
		Steps: make([]BuildStep, 0),
	}

	lines := strings.Split(output, "\n")
	stepsByID := make(map[int]*BuildStep)
	stepOrder := make([]int, 0)
	var currentStepID int

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}

		if matches := buildStepDoneRe.FindStringSubmatch(trimmed); len(matches) == 3 {
			stepID, _ := strconv.Atoi(matches[1])
			durationMs := parseBuildLogStepDurationMs(matches[2])
			step := ensureStep(stepsByID, &stepOrder, stepID)
			step.DurationMs = durationMs
			classifyTiming(&result.Timing, step.Name, durationMs)
			currentStepID = 0
			continue
		}

		if matches := buildStepCachedRe.FindStringSubmatch(trimmed); len(matches) == 2 {
			stepID, _ := strconv.Atoi(matches[1])
			step := ensureStep(stepsByID, &stepOrder, stepID)
			step.Cached = true
			currentStepID = 0
			continue
		}

		if matches := buildStepIndexRe.FindStringSubmatch(trimmed); len(matches) == 4 {
			stepID, _ := strconv.Atoi(matches[1])
			index, _ := strconv.Atoi(matches[2])
			total, _ := strconv.Atoi(matches[3])
			step := ensureStep(stepsByID, &stepOrder, stepID)
			step.Index = index
			step.Total = total
			rest := strings.TrimSpace(trimmed[len(matches[0]):])
			if rest != "" {
				step.Name = rest
			}
			currentStepID = stepID
			continue
		}

		if matches := buildStepHeaderRe.FindStringSubmatch(trimmed); len(matches) == 4 {
			stepID, _ := strconv.Atoi(matches[1])
			if currentStepID > 0 && stepID == currentStepID {
				step := stepsByID[currentStepID]
				if step != nil {
					if step.Log != "" {
						step.Log += "\n"
					}
					step.Log += trimmed
				}
				continue
			}

			step := ensureStep(stepsByID, &stepOrder, stepID)
			name := strings.TrimSpace(matches[3])
			if name != "" {
				step.Name = name
			}
			currentStepID = stepID
			continue
		}

		if strings.HasPrefix(trimmed, "#") && currentStepID > 0 {
			step := stepsByID[currentStepID]
			if step != nil {
				if step.Log != "" {
					step.Log += "\n"
				}
				step.Log += trimmed
			}
		}
	}

	for _, stepID := range stepOrder {
		step := stepsByID[stepID]
		if step == nil {
			continue
		}
		result.Steps = append(result.Steps, *step)
		if step.Cached {
			result.CachedSteps++
		}
	}

	result.TotalSteps = len(result.Steps)
	result.RawLog = output
	return result
}

// ApplyBuildLogs updates build with parsed steps, timing, and counts from raw build log output.
func ApplyBuildLogs(build *Build, logs string) {
	if build == nil || strings.TrimSpace(logs) == "" {
		return
	}

	parsed := ParseBuildOutput(logs)
	build.Steps = parsed.Steps
	build.Timing = parsed.Timing
	build.RawLog = parsed.RawLog
	if parsed.CachedSteps > 0 {
		build.CachedSteps = parsed.CachedSteps
	}
	if parsed.TotalSteps > 0 {
		build.TotalSteps = parsed.TotalSteps
	}
}

// ensureStep returns the build step for stepID, creating and tracking it on first use.
func ensureStep(steps map[int]*BuildStep, order *[]int, stepID int) *BuildStep {
	if step, ok := steps[stepID]; ok {
		return step
	}

	step := &BuildStep{}
	steps[stepID] = step
	*order = append(*order, stepID)
	return step
}

// parseBuildLogStepDurationMs converts a build-log duration string (e.g. "1.23s") to milliseconds.
func parseBuildLogStepDurationMs(value string) int64 {
	value = strings.TrimSuffix(value, "s")
	seconds, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return 0
	}

	return int64(seconds * float64(time.Second/time.Millisecond))
}

// classifyTiming accumulates step duration into the appropriate BuildTiming category by step name.
func classifyTiming(timing *BuildTiming, stepName string, durationMs int64) {
	lower := strings.ToLower(stepName)
	switch {
	case strings.Contains(lower, "load metadata") || strings.Contains(lower, "from "):
		timing.ImagePullsMs += durationMs
	case strings.Contains(lower, "transferring") || strings.Contains(lower, "load build context") || strings.Contains(lower, "load .dockerignore"):
		timing.LocalTransfersMs += durationMs
	case strings.Contains(lower, "exporting") || strings.Contains(lower, "export to"):
		timing.ResultExportsMs += durationMs
	case strings.Contains(lower, "resolve") || strings.Contains(lower, "load build definition"):
		timing.FileOperationsMs += durationMs
	case strings.Contains(lower, "run ") || strings.Contains(lower, "copy "):
		timing.ExecutionsMs += durationMs
	default:
		if durationMs == 0 {
			timing.IdleMs += durationMs
		} else if strings.Contains(lower, "internal") {
			timing.FileOperationsMs += durationMs
		} else {
			timing.ExecutionsMs += durationMs
		}
	}
}
