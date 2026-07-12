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

	"github.com/enegalan/calf/backend/internal/constants"
)

// Status represents the current state of the docker CLI context.
type Status struct {
	Available      bool   `json:"available"`
	CurrentContext string `json:"current_context"`
	CalfActive     bool   `json:"calf_active"`
	CalfExists     bool   `json:"calf_exists"`
	Managed        bool   `json:"managed"`
	Socket         string `json:"socket"`
}

// dockerConfig represents the current context of the docker CLI.
type dockerConfig struct {
	CurrentContext string `json:"currentContext"`
}

// StatusFor reports whether the docker CLI is available and how the calf context is configured.
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
	status.CalfActive = status.CurrentContext == constants.DockerContextName

	ctx, cancel := context.WithTimeout(context.Background(), constants.DefaultActionTimeout)
	defer cancel()
	status.CalfExists = contextExists(ctx, constants.DockerContextName)

	return status, nil
}

// readCurrentContext reads the active docker context name from ~/.docker/config.json.
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

// contextExists reports whether a named docker context is present.
func contextExists(ctx context.Context, name string) bool {
	command := exec.CommandContext(ctx, "docker", "context", "inspect", name, "--format", "{{.Name}}")
	output, err := command.Output()
	if err != nil {
		return false
	}

	return strings.TrimSpace(string(output)) == name
}

// EnsureContext creates or updates the calf docker context to point at the given socket.
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
	if contextExists(ctx, constants.DockerContextName) {
		return updateContext(ctx, host)
	}

	command := exec.CommandContext(ctx, "docker", "context", "create", constants.DockerContextName, "--docker", "host="+host)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker context create: %w: %s", err, strings.TrimSpace(string(output)))
	}

	return nil
}

// updateContext changes the docker host endpoint for an existing calf context.
func updateContext(ctx context.Context, host string) error {
	command := exec.CommandContext(ctx, "docker", "context", "update", constants.DockerContextName, "--docker", "host="+host)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker context update: %w: %s", err, strings.TrimSpace(string(output)))
	}

	return nil
}

// ActivateContext switches the active docker CLI context to calf.
func ActivateContext(ctx context.Context) error {
	if _, err := exec.LookPath("docker"); err != nil {
		return fmt.Errorf("docker CLI not found")
	}

	command := exec.CommandContext(ctx, "docker", "context", "use", constants.DockerContextName)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker context use: %w: %s", err, strings.TrimSpace(string(output)))
	}

	return nil
}

// EnsureAndActivate creates or updates the calf context and selects it when another context is active.
func EnsureAndActivate(ctx context.Context, socket string) error {
	if err := EnsureContext(ctx, socket); err != nil {
		return err
	}

	if readCurrentContext() == constants.DockerContextName {
		return nil
	}

	return ActivateContext(ctx)
}
