package buildstore

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/enegalan/calf/backend/internal/runtime"
)

const maxBuilds = 200

type File struct {
	Builds []runtime.Build `json:"builds"`
	Seq    int             `json:"seq"`
}

func Path() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(home, ".config", "calf", "builds.json"), nil
}

func Load() (File, error) {
	path, err := Path()
	if err != nil {
		return File{}, err
	}

	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return File{Builds: []runtime.Build{}}, nil
	}

	if err != nil {
		return File{}, err
	}

	var file File
	if err := json.Unmarshal(data, &file); err != nil {
		return File{}, err
	}

	if file.Builds == nil {
		file.Builds = []runtime.Build{}
	}

	return file, nil
}

func Save(builds []runtime.Build, seq int) error {
	path, err := Path()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	file := File{
		Builds: trimBuilds(builds),
		Seq:    seq,
	}

	data, err := json.MarshalIndent(file, "", "  ")
	if err != nil {
		return err
	}

	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0o644); err != nil {
		return err
	}

	return os.Rename(tmpPath, path)
}

// trimBuilds keeps the newest maxBuilds entries. Callers must maintain builds in newest-first order.
func trimBuilds(builds []runtime.Build) []runtime.Build {
	if len(builds) <= maxBuilds {
		return builds
	}

	return builds[:maxBuilds]
}
