package config

import (
	_ "embed"
	"errors"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"

	"github.com/enegalan/calf/backend/internal/constants"
)

//go:embed config.yaml
var defaultConfigYAML []byte

// Config represents the configuration for the application.
type Config struct {
	ListenAddr           string `yaml:"listen_addr"`
	LogLevel             string `yaml:"log_level"`
	VMName               string `yaml:"vm_name"`
	DockerSocket         string `yaml:"docker_socket"`
	PollIntervalMs       int    `yaml:"poll_interval_ms"`
	DockerContextManaged bool   `yaml:"docker_context_managed"`
	CPUs                 int    `yaml:"cpus"`
	MemoryGB             int    `yaml:"memory_gb"`
	MemorySwapGB         int    `yaml:"memory_swap_gb"`
	DiskGB               int    `yaml:"disk_gb"`
	HTTPProxy            string `yaml:"http_proxy"`
	HTTPSProxy           string `yaml:"https_proxy"`
	NoProxy              string `yaml:"no_proxy"`
	VMKeepAlive          bool   `yaml:"vm_keep_alive"`
}

// Default returns the embedded config.yaml values without reading disk.
func Default() Config {
	return defaultFromYAML()
}

// defaultFromYAML unmarshals the embedded config.yaml template.
func defaultFromYAML() Config {
	var cfg Config
	_ = yaml.Unmarshal(defaultConfigYAML, &cfg)
	return cfg
}

// Path returns the absolute path to ~/.config/calf/config.yaml.
func Path() (string, error) {
	dir, err := ConfigDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(dir, "config.yaml"), nil
}

// Load reads config from disk, writing defaults on first run, and backfills zero values.
func Load() (Config, error) {
	cfg := Default()

	path, err := Path()
	if err != nil {
		return cfg, err
	}

	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		if saveErr := Save(cfg); saveErr != nil {
			return cfg, saveErr
		}

		return cfg, nil
	}

	if err != nil {
		return cfg, err
	}

	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return cfg, err
	}

	var raw map[string]any
	_ = yaml.Unmarshal(data, &raw)
	if _, ok := raw["docker_context_managed"]; !ok {
		cfg.DockerContextManaged = defaultFromYAML().DockerContextManaged
	}
	if _, ok := raw["vm_keep_alive"]; !ok {
		cfg.VMKeepAlive = defaultFromYAML().VMKeepAlive
	}

	cfg = withDefaults(cfg)
	return cfg, nil
}

// Save writes cfg to disk after applying defaults to empty fields.
func Save(cfg Config) error {
	path, err := Path()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	cfg = withDefaults(cfg)

	data, err := yaml.Marshal(cfg)
	if err != nil {
		return err
	}

	return os.WriteFile(path, data, 0o644)
}

// withDefaults fills zero or negative fields from embedded defaults so callers never see empty config.
func withDefaults(cfg Config) Config {
	defaults := defaultFromYAML()

	if cfg.ListenAddr == "" {
		cfg.ListenAddr = constants.DefaultListenAddr
	}

	if cfg.LogLevel == "" {
		cfg.LogLevel = defaults.LogLevel
	}

	if cfg.VMName == "" {
		cfg.VMName = constants.DefaultVMName
	}

	if cfg.PollIntervalMs <= 0 {
		cfg.PollIntervalMs = constants.DefaultPollIntervalMS
	}

	if cfg.CPUs <= 0 {
		cfg.CPUs = defaults.CPUs
	}

	if cfg.MemoryGB <= 0 {
		cfg.MemoryGB = defaults.MemoryGB
	}

	if cfg.MemorySwapGB <= 0 {
		cfg.MemorySwapGB = defaults.MemorySwapGB
	}

	if cfg.DiskGB <= 0 {
		cfg.DiskGB = defaults.DiskGB
	}

	return cfg
}
