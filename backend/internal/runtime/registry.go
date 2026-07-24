package runtime

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/enegalan/calf/backend/internal/constants"
)

// RegistryStatus represents the status of a registry.
type RegistryStatus struct {
	LoggedIn bool   `json:"logged_in"`
	Server   string `json:"server"`
	Username string `json:"username,omitempty"`
}

// dockerConfigFile represents a Docker config file.
type dockerConfigFile struct {
	Auths       map[string]dockerConfigAuth `json:"auths"`
	CredsStore  string                      `json:"credsStore"`
	CredHelpers map[string]string           `json:"credHelpers"`
}

// dockerConfigAuth represents an authentication entry in a Docker config file.
type dockerConfigAuth struct {
	Auth string `json:"auth"`
}

// dockerCredentialHelperPayload is the JSON returned by docker-credential-* get.
type dockerCredentialHelperPayload struct {
	Username string `json:"Username"`
}

// registryLogin authenticates nerdctl against the given registry using password-stdin.
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

// registryLogout removes nerdctl credentials for the given registry server.
func registryLogout(ctx context.Context, run commandRunner, server string) error {
	server = strings.TrimSpace(server)
	args := []string{"logout"}
	if server != "" && !isDockerHubRegistry(server) {
		args = append(args, server)
	}

	_, err := run(ctx, "nerdctl", args...)
	return err
}

// isDockerHubRegistry reports whether server refers to Docker Hub or its canonical aliases.
func isDockerHubRegistry(server string) bool {
	server = strings.ToLower(strings.TrimSpace(server))
	if server == "" {
		return true
	}

	for _, key := range constants.DockerHubRegistryKeys {
		if server == strings.ToLower(key) {
			return true
		}
	}

	return strings.Contains(server, "docker.io")
}

// registryStatus reads Docker config files and returns login state for the first match.
// When auth is stored via credsStore/credHelpers (empty auth field), it queries the helper.
func registryStatus(ctx context.Context, run commandRunner, runWithStdin stdinCommandRunner, paths ...string) (RegistryStatus, error) {
	status := RegistryStatus{
		LoggedIn: false,
		Server:   constants.DefaultRegistryServer,
	}

	for _, path := range paths {
		output, err := run(ctx, "cat", path)
		if err != nil {
			continue
		}

		if parsed := RegistryStatusFromConfig(output); parsed.LoggedIn {
			return parsed, nil
		}

		if runWithStdin == nil {
			continue
		}

		if parsed := RegistryStatusFromCredentialHelpers(output, func(helper, serverURL string) (string, bool) {
			return lookupCredentialUsername(ctx, runWithStdin, helper, serverURL)
		}); parsed.LoggedIn {
			return parsed, nil
		}
	}

	return status, nil
}

// RegistryStatusFromConfig parses a Docker config.json payload into registry login status.
func RegistryStatusFromConfig(output []byte) RegistryStatus {
	status := RegistryStatus{
		LoggedIn: false,
		Server:   constants.DefaultRegistryServer,
	}

	if username, ok := dockerConfigCredentials(output); ok {
		status.LoggedIn = true
		status.Username = username
	}

	return status
}

// dockerConfigCredentials extracts the Docker Hub username from a config.json auths section.
func dockerConfigCredentials(output []byte) (string, bool) {
	var config dockerConfigFile
	if err := json.Unmarshal(output, &config); err != nil {
		return "", false
	}

	for _, key := range constants.DockerHubRegistryKeys {
		if username, ok := dockerConfigAuthUsername(config.Auths[key]); ok {
			return username, true
		}
	}

	for key, auth := range config.Auths {
		if strings.Contains(key, constants.DefaultRegistryServer) {
			if username, ok := dockerConfigAuthUsername(auth); ok {
				return username, true
			}
		}
	}

	return "", false
}

// RegistryStatusFromCredentialHelpers resolves Docker Hub login via credsStore/credHelpers.
// lookup returns the username for helper+serverURL, or false when credentials are missing.
func RegistryStatusFromCredentialHelpers(output []byte, lookup func(helper, serverURL string) (string, bool)) RegistryStatus {
	status := RegistryStatus{
		LoggedIn: false,
		Server:   constants.DefaultRegistryServer,
	}

	if lookup == nil {
		return status
	}

	var config dockerConfigFile
	if err := json.Unmarshal(output, &config); err != nil {
		return status
	}

	for _, key := range constants.DockerHubRegistryKeys {
		helper := credentialHelperFor(config, key)
		if helper == "" {
			continue
		}

		username, ok := lookup(helper, key)
		if !ok {
			continue
		}

		status.LoggedIn = true
		status.Username = username
		return status
	}

	return status
}

// lookupCredentialUsername asks a docker-credential-* helper for the username of serverURL.
func lookupCredentialUsername(ctx context.Context, runWithStdin stdinCommandRunner, helper, serverURL string) (string, bool) {
	helper = strings.TrimSpace(helper)
	if !isSafeCredentialHelperName(helper) {
		return "", false
	}

	output, err := runWithStdin(ctx, serverURL+"\n", "docker-credential-"+helper, "get")
	if err != nil {
		return "", false
	}

	username, ok := ParseCredentialHelperUsername(output)
	return username, ok
}

// ParseCredentialHelperUsername extracts the username from docker-credential-* get JSON.
func ParseCredentialHelperUsername(output []byte) (string, bool) {
	var payload dockerCredentialHelperPayload
	if err := json.Unmarshal(output, &payload); err != nil {
		return "", false
	}

	username := strings.TrimSpace(payload.Username)
	if username == "" {
		return "", false
	}

	return username, true
}

// credentialHelperFor returns the docker-credential helper name for a registry key.
func credentialHelperFor(config dockerConfigFile, registryKey string) string {
	if helper, ok := config.CredHelpers[registryKey]; ok {
		helper = strings.TrimSpace(helper)
		if helper != "" {
			return helper
		}
	}

	if _, hasAuth := config.Auths[registryKey]; hasAuth {
		return strings.TrimSpace(config.CredsStore)
	}

	return ""
}

// isSafeCredentialHelperName reports whether name is a safe docker-credential helper suffix.
func isSafeCredentialHelperName(name string) bool {
	if name == "" {
		return false
	}

	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z':
		case r >= 'A' && r <= 'Z':
		case r >= '0' && r <= '9':
		case r == '-' || r == '_':
		default:
			return false
		}
	}

	return true
}

// dockerConfigAuthUsername decodes the base64 auth field and returns the username portion.
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
