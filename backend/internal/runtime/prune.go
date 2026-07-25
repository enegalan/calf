package runtime

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/enegalan/calf/backend/internal/utils"
)

// ErrPruneCategoryRequired is returned when Prune is called with no categories selected.
var ErrPruneCategoryRequired = errors.New("select at least one prune category")


// PruneOptions selects which unused resource categories to remove.
type PruneOptions struct {
	Containers bool `json:"containers"`
	Images     bool `json:"images"`
	Volumes    bool `json:"volumes"`
	Networks   bool `json:"networks"`
	BuildCache bool `json:"build_cache"`
}

// PruneItem is one reclaimable resource shown in the clean-disk preview.
type PruneItem struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Size      string `json:"size,omitempty"`
	SizeBytes int64  `json:"size_bytes"`
}

// PruneCategoryPreview lists reclaimable items for one prune category.
type PruneCategoryPreview struct {
	Items             []PruneItem `json:"items"`
	ReclaimableBytes  int64       `json:"reclaimable_bytes"`
	ReclaimableSize   string      `json:"reclaimable_size"`
}

// PrunePreview is the clean-disk preview for all prune categories.
type PrunePreview struct {
	Containers            PruneCategoryPreview `json:"containers"`
	Images                PruneCategoryPreview `json:"images"`
	Volumes               PruneCategoryPreview `json:"volumes"`
	Networks              PruneCategoryPreview `json:"networks"`
	BuildCache            PruneCategoryPreview `json:"build_cache"`
	DiskUsage             SystemDiskUsage      `json:"disk_usage"`
	TotalReclaimableBytes int64                `json:"total_reclaimable_bytes"`
	TotalReclaimableSize  string               `json:"total_reclaimable_size"`
}

// PruneResult reports which categories were pruned and estimated reclaimed bytes.
type PruneResult struct {
	Containers bool  `json:"containers"`
	Images     bool  `json:"images"`
	Volumes    bool  `json:"volumes"`
	Networks   bool  `json:"networks"`
	BuildCache bool  `json:"build_cache"`
	ReclaimedBytes int64  `json:"reclaimed_bytes"`
	ReclaimedSize  string `json:"reclaimed_size"`
}

// prunePreview builds a reclaimable-data preview by listing unused resources.
func prunePreview(ctx context.Context, run commandRunner) (PrunePreview, error) {
	containers, err := listContainers(ctx, run)
	if err != nil {
		return PrunePreview{}, fmt.Errorf("list containers for prune preview: %w", err)
	}

	images, err := listImages(ctx, run)
	if err != nil {
		return PrunePreview{}, fmt.Errorf("list images for prune preview: %w", err)
	}

	volumes, err := listVolumes(ctx, run)
	if err != nil {
		return PrunePreview{}, fmt.Errorf("list volumes for prune preview: %w", err)
	}
	volumes, err = enrichVolumesInUse(ctx, run, volumes)
	if err != nil {
		return PrunePreview{}, fmt.Errorf("enrich volumes for prune preview: %w", err)
	}

	networks, err := listNetworks(ctx, run)
	if err != nil {
		return PrunePreview{}, fmt.Errorf("list networks for prune preview: %w", err)
	}

	preview := PrunePreview{
		Containers: categoryFromItems(stoppedContainerPruneItems(containers)),
		Images:     categoryFromItems(unusedImagePruneItems(containers, images)),
		Volumes:    categoryFromItems(unusedVolumePruneItems(volumes)),
		Networks:   categoryFromItems(unusedNetworkPruneItems(networks)),
		BuildCache: buildCachePruneCategory(ctx, run),
	}
	if usage, dfErr := systemDiskUsage(ctx, run); dfErr == nil {
		preview.DiskUsage = usage
	} else {
		preview.DiskUsage = SystemDiskUsage{Rows: []DiskUsageRow{}}
	}
	preview.TotalReclaimableBytes = preview.Containers.ReclaimableBytes +
		preview.Images.ReclaimableBytes +
		preview.Volumes.ReclaimableBytes +
		preview.Networks.ReclaimableBytes +
		preview.BuildCache.ReclaimableBytes
	preview.TotalReclaimableSize = utils.FormatBytes(preview.TotalReclaimableBytes)
	return preview, nil
}

// prune removes unused resources for the selected categories.
func prune(ctx context.Context, run commandRunner, opts PruneOptions) (PruneResult, error) {
	if !opts.Containers && !opts.Images && !opts.Volumes && !opts.Networks && !opts.BuildCache {
		return PruneResult{}, ErrPruneCategoryRequired
	}

	preview, err := prunePreview(ctx, run)
	if err != nil {
		return PruneResult{}, err
	}

	var reclaimed int64
	result := PruneResult{}

	if opts.Containers {
		if _, err := run(ctx, "nerdctl", "container", "prune", "-f"); err != nil {
			return PruneResult{}, fmt.Errorf("prune containers: %w", err)
		}
		result.Containers = true
		reclaimed += preview.Containers.ReclaimableBytes
	}
	if opts.Networks {
		if _, err := run(ctx, "nerdctl", "network", "prune", "-f"); err != nil {
			return PruneResult{}, fmt.Errorf("prune networks: %w", err)
		}
		result.Networks = true
		reclaimed += preview.Networks.ReclaimableBytes
	}
	if opts.Images {
		if _, err := run(ctx, "nerdctl", "image", "prune", "-a", "-f"); err != nil {
			return PruneResult{}, fmt.Errorf("prune images: %w", err)
		}
		result.Images = true
		reclaimed += preview.Images.ReclaimableBytes
	}
	if opts.Volumes {
		if _, err := run(ctx, "nerdctl", "volume", "prune", "-f"); err != nil {
			return PruneResult{}, fmt.Errorf("prune volumes: %w", err)
		}
		result.Volumes = true
		reclaimed += preview.Volumes.ReclaimableBytes
	}
	if opts.BuildCache {
		if err := pruneBuildCache(ctx, run); err != nil {
			return PruneResult{}, err
		}
		result.BuildCache = true
		reclaimed += preview.BuildCache.ReclaimableBytes
	}

	result.ReclaimedBytes = reclaimed
	result.ReclaimedSize = utils.FormatBytes(reclaimed)
	return result, nil
}

// pruneBuildCache removes unused build cache via builder prune, falling back to buildx.
func pruneBuildCache(ctx context.Context, run commandRunner) error {
	if _, err := run(ctx, "nerdctl", "builder", "prune", "-a", "-f"); err == nil {
		return nil
	} else if _, fallbackErr := run(ctx, "nerdctl", "buildx", "prune", "-a", "-f"); fallbackErr == nil {
		return nil
	} else {
		return fmt.Errorf("prune build cache: %w", err)
	}
}

// categoryFromItems builds a category preview from prune items.
func categoryFromItems(items []PruneItem) PruneCategoryPreview {
	var total int64
	for _, item := range items {
		total += item.SizeBytes
	}
	if items == nil {
		items = []PruneItem{}
	}
	return PruneCategoryPreview{
		Items:            items,
		ReclaimableBytes: total,
		ReclaimableSize:  utils.FormatBytes(total),
	}
}

// stoppedContainerPruneItems returns containers that container prune would remove.
func stoppedContainerPruneItems(containers []Container) []PruneItem {
	items := make([]PruneItem, 0)
	for _, container := range containers {
		if containerKeptAlive(container.State) {
			continue
		}
		name := strings.TrimSpace(container.Name)
		if name == "" {
			name = container.ID
		}
		items = append(items, PruneItem{
			ID:   container.ID,
			Name: name,
		})
	}
	return items
}

// unusedImagePruneItems returns images not used by any container (image prune -a).
func unusedImagePruneItems(containers []Container, images []Image) []PruneItem {
	used := usedImageKeys(containers, images)
	items := make([]PruneItem, 0)
	seen := map[string]struct{}{}
	for _, image := range images {
		key := image.ID
		if key == "" {
			key = imageReference(image)
		}
		if _, ok := seen[key]; ok {
			continue
		}
		if imageIsUsed(image, used) {
			continue
		}
		seen[key] = struct{}{}
		sizeBytes := parseResourceSize(image.Size)
		name := imageReference(image)
		if name == "" || name == ":" {
			name = image.ID
		}
		items = append(items, PruneItem{
			ID:        image.ID,
			Name:      name,
			Size:      image.Size,
			SizeBytes: sizeBytes,
		})
	}
	return items
}

// unusedVolumePruneItems returns volumes not currently in use.
func unusedVolumePruneItems(volumes []Volume) []PruneItem {
	items := make([]PruneItem, 0)
	for _, volume := range volumes {
		if volume.InUse {
			continue
		}
		sizeBytes := parseResourceSize(volume.Size)
		items = append(items, PruneItem{
			ID:        volume.Name,
			Name:      volume.Name,
			Size:      volume.Size,
			SizeBytes: sizeBytes,
		})
	}
	return items
}

// unusedNetworkPruneItems returns non-default networks as prune candidates.
func unusedNetworkPruneItems(networks []Network) []PruneItem {
	items := make([]PruneItem, 0)
	for _, network := range networks {
		if isDefaultNetwork(network.Name) {
			continue
		}
		items = append(items, PruneItem{
			ID:   network.ID,
			Name: network.Name,
		})
	}
	return items
}

// buildCachePruneCategory reads reclaimable build cache from system df when available.
func buildCachePruneCategory(ctx context.Context, run commandRunner) PruneCategoryPreview {
	reclaimable, sizeLabel, ok := systemDfReclaimable(ctx, run, "Build Cache")
	if !ok {
		return PruneCategoryPreview{
			Items:            []PruneItem{},
			ReclaimableBytes: 0,
			ReclaimableSize:  utils.FormatBytes(0),
		}
	}
	if reclaimable <= 0 {
		return PruneCategoryPreview{
			Items:            []PruneItem{},
			ReclaimableBytes: 0,
			ReclaimableSize:  utils.FormatBytes(0),
		}
	}
	label := sizeLabel
	if label == "" {
		label = utils.FormatBytes(reclaimable)
	}
	return PruneCategoryPreview{
		Items: []PruneItem{{
			ID:        "build-cache",
			Name:      "Build cache",
			Size:      label,
			SizeBytes: reclaimable,
		}},
		ReclaimableBytes: reclaimable,
		ReclaimableSize:  utils.FormatBytes(reclaimable),
	}
}

// systemDfReclaimable parses docker/nerdctl system df reclaimable bytes for a type row.
func systemDfReclaimable(ctx context.Context, run commandRunner, typeName string) (int64, string, bool) {
	output, err := run(ctx, "nerdctl", "system", "df", "--format", "{{.Type}}\t{{.Reclaimable}}")
	if err != nil {
		return 0, "", false
	}
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Split(strings.TrimSpace(line), "\t")
		if len(fields) != 2 {
			continue
		}
		if !strings.EqualFold(fields[0], typeName) {
			continue
		}
		raw := strings.TrimSpace(fields[1])
		if before, _, cut := strings.Cut(raw, "("); cut {
			raw = strings.TrimSpace(before)
		}
		sizeBytes, parseErr := utils.ParseDockerHumanSize(raw)
		if parseErr != nil {
			sizeBytes = parseResourceSize(raw)
		}
		return sizeBytes, raw, true
	}
	return 0, "", false
}

// containerKeptAlive reports whether a container is kept by container prune.
func containerKeptAlive(state string) bool {
	switch strings.ToLower(strings.TrimSpace(state)) {
	case "running", "restarting", "paused", "removing":
		return true
	default:
		return false
	}
}

// isDefaultNetwork reports networks that network prune never removes.
func isDefaultNetwork(name string) bool {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "bridge", "host", "none":
		return true
	default:
		return false
	}
}

// usedImageKeys collects image id/name keys referenced by containers.
func usedImageKeys(containers []Container, images []Image) map[string]struct{} {
	used := map[string]struct{}{}
	for _, container := range containers {
		ref := strings.TrimSpace(container.Image)
		if ref == "" {
			continue
		}
		used[ref] = struct{}{}
		used[shortImageID(ref)] = struct{}{}
		for _, image := range images {
			if imageMatchesRef(image, ref) {
				if image.ID != "" {
					used[image.ID] = struct{}{}
					used[shortImageID(image.ID)] = struct{}{}
				}
				used[imageReference(image)] = struct{}{}
			}
		}
	}
	return used
}

// imageIsUsed reports whether an image is referenced by the used-key set.
func imageIsUsed(image Image, used map[string]struct{}) bool {
	candidates := []string{
		image.ID,
		shortImageID(image.ID),
		imageReference(image),
	}
	if image.Repository != "" && image.Repository != "<none>" {
		candidates = append(candidates, image.Repository)
		if image.Tag != "" && image.Tag != "<none>" {
			candidates = append(candidates, image.Repository+":"+image.Tag)
		}
	}
	for _, candidate := range candidates {
		candidate = strings.TrimSpace(candidate)
		if candidate == "" {
			continue
		}
		if _, ok := used[candidate]; ok {
			return true
		}
	}
	return false
}

// imageMatchesRef reports whether an image matches a container image reference.
func imageMatchesRef(image Image, ref string) bool {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return false
	}
	if image.ID == ref || shortImageID(image.ID) == shortImageID(ref) {
		return true
	}
	full := imageReference(image)
	if full == ref {
		return true
	}
	if image.Repository != "" && (image.Repository == ref || image.Repository+":latest" == ref) {
		return true
	}
	return strings.HasPrefix(image.ID, ref) || strings.HasPrefix(ref, shortImageID(image.ID))
}

// imageReference returns repository:tag for an image.
func imageReference(image Image) string {
	repo := strings.TrimSpace(image.Repository)
	tag := strings.TrimSpace(image.Tag)
	if repo == "" || repo == "<none>" {
		return ""
	}
	if tag == "" || tag == "<none>" {
		return repo
	}
	return repo + ":" + tag
}

// shortImageID returns the leading id segment without a sha256: prefix.
func shortImageID(id string) string {
	id = strings.TrimPrefix(strings.TrimSpace(id), "sha256:")
	if len(id) > 12 {
		return id[:12]
	}
	return id
}

// parseResourceSize converts common Docker/du size strings to bytes; unknown formats yield 0.
func parseResourceSize(value string) int64 {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}
	if bytes, err := utils.ParseDockerHumanSize(value); err == nil {
		return bytes
	}

	compact := strings.ReplaceAll(value, " ", "")
	units := []struct {
		suffix string
		mult   float64
	}{
		{"GiB", 1024 * 1024 * 1024},
		{"MiB", 1024 * 1024},
		{"KiB", 1024},
		{"GB", 1000 * 1000 * 1000},
		{"MB", 1000 * 1000},
		{"kB", 1000},
		{"KB", 1000},
		{"G", 1024 * 1024 * 1024},
		{"M", 1024 * 1024},
		{"K", 1024},
		{"B", 1},
	}
	for _, unit := range units {
		if strings.HasSuffix(compact, unit.suffix) {
			number := strings.TrimSuffix(compact, unit.suffix)
			parsed, err := strconv.ParseFloat(number, 64)
			if err != nil {
				return 0
			}
			return int64(parsed * unit.mult)
		}
	}
	return 0
}
