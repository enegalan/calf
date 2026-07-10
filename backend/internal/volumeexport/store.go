package volumeexport

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	TypeLocalFile  = "local_file"
	TypeLocalImage = "local_image"
	TypeNewImage   = "new_image"
	TypeRegistry   = "registry"

	StatusRunning   = "running"
	StatusCompleted = "completed"
	StatusFailed    = "failed"
)

type Export struct {
	ID           string `json:"id"`
	Volume       string `json:"volume"`
	Type         string `json:"type"`
	Status       string `json:"status"`
	CreatedAt    string `json:"created_at"`
	FileName     string `json:"file_name,omitempty"`
	FilePath     string `json:"file_path,omitempty"`
	ImageRef     string `json:"image_ref,omitempty"`
	Size         string `json:"size,omitempty"`
	Error        string `json:"error,omitempty"`
	Downloadable bool   `json:"downloadable"`
}

type Store struct {
	root string
}

// NewStore creates a Store rooted at ~/.config/calf/mounts/volume-exports.
func NewStore() (*Store, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("resolve home dir: %w", err)
	}

	root := filepath.Join(home, ".config", "calf", "mounts", "volume-exports")
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, fmt.Errorf("create export root: %w", err)
	}

	return &Store{root: root}, nil
}

// List returns all exports for volumeName, sorted newest first.
func (s *Store) List(volumeName string) ([]Export, error) {
	volumeDir := s.volumeDir(volumeName)
	entries, err := os.ReadDir(volumeDir)
	if err != nil {
		if os.IsNotExist(err) {
			return []Export{}, nil
		}

		return nil, fmt.Errorf("list exports for %s: %w", volumeName, err)
	}

	exports := make([]Export, 0, len(entries))
	var skipped []error
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		export, err := s.readMeta(volumeName, entry.Name())
		if err != nil {
			skipped = append(skipped, fmt.Errorf("volume %s export %s: %w", volumeName, entry.Name(), err))
			continue
		}

		exports = append(exports, export)
	}

	sort.Slice(exports, func(i, j int) bool {
		return exports[i].CreatedAt > exports[j].CreatedAt
	})

	return exports, errors.Join(skipped...)
}

// Get returns the export metadata for volumeName and id.
func (s *Store) Get(volumeName, id string) (Export, error) {
	return s.readMeta(volumeName, id)
}

// Save persists export metadata to disk, creating the export directory when needed.
func (s *Store) Save(export Export) error {
	if strings.TrimSpace(export.Volume) == "" {
		return fmt.Errorf("volume is required")
	}

	if strings.TrimSpace(export.ID) == "" {
		return fmt.Errorf("id is required")
	}

	dir, err := s.ensureExportDir(export.Volume, export.ID)
	if err != nil {
		return err
	}

	payload, err := json.MarshalIndent(export, "", "  ")
	if err != nil {
		return fmt.Errorf("encode export meta: %w", err)
	}

	metaPath := filepath.Join(dir, "meta.json")
	if err := os.WriteFile(metaPath, payload, 0o644); err != nil {
		return fmt.Errorf("write export meta: %w", err)
	}

	return nil
}

// NewID generates a unique export identifier for volumeName.
func (s *Store) NewID(volumeName string) string {
	return fmt.Sprintf("%s-%d", sanitizeName(volumeName), time.Now().UnixNano())
}

// ArchivePath returns the on-disk path for an export's archive.tar.gz file.
func (s *Store) ArchivePath(volumeName, id string) string {
	return filepath.Join(s.exportDir(volumeName, id), "archive.tar.gz")
}

// EnsureExportDir creates and returns the directory for volumeName and id.
func (s *Store) EnsureExportDir(volumeName, id string) (string, error) {
	return s.ensureExportDir(volumeName, id)
}

// ensureExportDir creates and returns the export directory for volumeName and id.
func (s *Store) ensureExportDir(volumeName, id string) (string, error) {
	dir := s.exportDir(volumeName, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("create export dir: %w", err)
	}

	return dir, nil
}

// readMeta loads export metadata from disk for volumeName and id.
func (s *Store) readMeta(volumeName, id string) (Export, error) {
	metaPath := filepath.Join(s.exportDir(volumeName, id), "meta.json")
	payload, err := os.ReadFile(metaPath)
	if err != nil {
		return Export{}, fmt.Errorf("read export meta: %w", err)
	}

	var export Export
	if err := json.Unmarshal(payload, &export); err != nil {
		return Export{}, fmt.Errorf("decode export meta: %w", err)
	}

	return export, nil
}

// volumeDir returns the on-disk directory for all exports of volumeName.
func (s *Store) volumeDir(volumeName string) string {
	return filepath.Join(s.root, sanitizeName(volumeName))
}

// exportDir returns the on-disk directory for a single export.
func (s *Store) exportDir(volumeName, id string) string {
	return filepath.Join(s.volumeDir(volumeName), sanitizeName(id))
}

// sanitizeName makes a value safe for use as a directory or file name component.
func sanitizeName(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "unknown"
	}

	replacer := strings.NewReplacer("/", "_", "\\", "_", ":", "_")
	value = replacer.Replace(value)
	if value == "." || value == ".." || strings.Contains(value, "..") {
		return "unknown"
	}

	return value
}
