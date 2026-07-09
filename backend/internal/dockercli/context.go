package dockercli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const ContextName = "calf"
const cliTimeout = 30 * time.Second

type Status struct {
	Available      bool   `json:"available"`
	CurrentContext string `json:"current_context"`
	CalfActive     bool   `json:"calf_active"`
	CalfExists     bool   `json:"calf_exists"`
	Managed        bool   `json:"managed"`
	Socket         string `json:"socket"`
}

type dockerConfig struct {
	CurrentContext string `json:"currentContext"`
}

func StatusFor(socket string, managed bool) (Status, error) {
	status := Status{
		Managed:        managed,
		Socket:         socket,
		CurrentContext: readCurrentContext(),
	}

	if _, err := exec.LookPath("docker"); err != nil {
		return status, nil
	}

	status.Available = true
	status.CalfActive = status.CurrentContext == ContextName

	ctx, cancel := context.WithTimeout(context.Background(), cliTimeout)
	defer cancel()
	status.CalfExists = contextExists(ctx, ContextName)

	return status, nil
}

func readCurrentContext() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}

	data, err := os.ReadFile(filepath.Join(home, ".docker", "config.json"))
	if err != nil {
		return ""
	}

	var cfg dockerConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return ""
	}

	return cfg.CurrentContext
}

func contextExists(ctx context.Context, name string) bool {
	command := exec.CommandContext(ctx, "docker", "context", "inspect", name, "--format", "{{.Name}}")
	output, err := command.Output()
	if err != nil {
		return false
	}

	return strings.TrimSpace(string(output)) == name
}

func EnsureContext(ctx context.Context, socket string) error {
	if socket == "" {
		return errors.New("docker socket path is empty")
	}

	if _, err := exec.LookPath("docker"); err != nil {
		return fmt.Errorf("docker CLI not found")
	}

	absSocket, err := filepath.Abs(socket)
	if err != nil {
		return err
	}

	host := "unix://" + absSocket
	if contextExists(ctx, ContextName) {
		return updateContext(ctx, host)
	}

	command := exec.CommandContext(ctx, "docker", "context", "create", ContextName, "--docker", "host="+host)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker context create: %w: %s", err, strings.TrimSpace(string(output)))
	}

	return nil
}

func updateContext(ctx context.Context, host string) error {
	command := exec.CommandContext(ctx, "docker", "context", "update", ContextName, "--docker", "host="+host)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker context update: %w: %s", err, strings.TrimSpace(string(output)))
	}

	return nil
}

func ActivateContext(ctx context.Context) error {
	if _, err := exec.LookPath("docker"); err != nil {
		return fmt.Errorf("docker CLI not found")
	}

	command := exec.CommandContext(ctx, "docker", "context", "use", ContextName)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker context use: %w: %s", err, strings.TrimSpace(string(output)))
	}

	return nil
}

func EnsureAndActivate(ctx context.Context, socket string) error {
	if err := EnsureContext(ctx, socket); err != nil {
		return err
	}

	if readCurrentContext() == ContextName {
		return nil
	}

	return ActivateContext(ctx)
}
