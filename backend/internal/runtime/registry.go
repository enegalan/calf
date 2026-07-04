package runtime

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
)

const defaultRegistryServer = "docker.io"

var dockerHubRegistryKeys = []string{
	"https://index.docker.io/v1/",
	"index.docker.io",
	"docker.io",
	"https://registry-1.docker.io/v2/",
}

type RegistryStatus struct {
	LoggedIn bool   `json:"logged_in"`
	Server   string `json:"server"`
	Username string `json:"username,omitempty"`
}

type dockerConfigFile struct {
	Auths map[string]dockerConfigAuth `json:"auths"`
}

type dockerConfigAuth struct {
	Auth string `json:"auth"`
}

func registryLogin(ctx context.Context, run commandRunner, runWithStdin stdinCommandRunner, server, username, password string) error {
	if strings.TrimSpace(username) == "" {
		return fmt.Errorf("username is required")
	}

	if strings.TrimSpace(password) == "" {
		return fmt.Errorf("password or token is required")
	}

	server = strings.TrimSpace(server)
	args := []string{"login", "--username", username, "--password-stdin"}
	if server != "" && !isDockerHubRegistry(server) {
		args = append(args, server)
	}

	_, err := runWithStdin(ctx, password, "nerdctl", args...)
	return err
}

func registryLogout(ctx context.Context, run commandRunner, server string) error {
	server = strings.TrimSpace(server)
	args := []string{"logout"}
	if server != "" && !isDockerHubRegistry(server) {
		args = append(args, server)
	}

	_, err := run(ctx, "nerdctl", args...)
	return err
}

func isDockerHubRegistry(server string) bool {
	switch strings.ToLower(server) {
	case "", defaultRegistryServer, "index.docker.io", "registry-1.docker.io", "https://index.docker.io/v1/", "https://registry-1.docker.io/v2/":
		return true
	default:
		return strings.Contains(strings.ToLower(server), "docker.io")
	}
}

func registryStatus(ctx context.Context, run commandRunner, paths ...string) (RegistryStatus, error) {
	status := RegistryStatus{
		LoggedIn: false,
		Server:   defaultRegistryServer,
	}

	for _, path := range paths {
		output, err := run(ctx, "cat", path)
		if err != nil {
			continue
		}

		if parsed := RegistryStatusFromConfig(output); parsed.LoggedIn {
			return parsed, nil
		}
	}

	return status, nil
}

func RegistryStatusFromConfig(output []byte) RegistryStatus {
	status := RegistryStatus{
		LoggedIn: false,
		Server:   defaultRegistryServer,
	}

	if username, ok := dockerConfigCredentials(output); ok {
		status.LoggedIn = true
		status.Username = username
	}

	return status
}

func dockerConfigCredentials(output []byte) (string, bool) {
	var config dockerConfigFile
	if err := json.Unmarshal(output, &config); err != nil {
		return "", false
	}

	for _, key := range dockerHubRegistryKeys {
		if username, ok := dockerConfigAuthUsername(config.Auths[key]); ok {
			return username, true
		}
	}

	for key, auth := range config.Auths {
		if strings.Contains(key, "docker.io") {
			if username, ok := dockerConfigAuthUsername(auth); ok {
				return username, true
			}
		}
	}

	return "", false
}

func dockerConfigAuthUsername(auth dockerConfigAuth) (string, bool) {
	if strings.TrimSpace(auth.Auth) == "" {
		return "", false
	}

	decoded, err := base64.StdEncoding.DecodeString(auth.Auth)
	if err != nil {
		return "", true
	}

	parts := strings.SplitN(string(decoded), ":", 2)
	if len(parts) == 0 || parts[0] == "" {
		return "", true
	}

	return parts[0], true
}
