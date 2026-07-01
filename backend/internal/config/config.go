package config

import (
	"errors"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

const (
	DefaultListenAddr = ":8080"
	DefaultLogLevel   = "info"
)

type Config struct {
	ListenAddr string `yaml:"listen_addr"`
	LogLevel   string `yaml:"log_level"`
}

func Default() Config {
	return Config{
		ListenAddr: DefaultListenAddr,
		LogLevel:   DefaultLogLevel,
	}
}

func Path() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(home, ".config", "calf", "config.yaml"), nil
}

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

	cfg = withDefaults(cfg)

	return cfg, nil
}

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

func withDefaults(cfg Config) Config {
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = DefaultListenAddr
	}

	if cfg.LogLevel == "" {
		cfg.LogLevel = DefaultLogLevel
	}

	return cfg
}
