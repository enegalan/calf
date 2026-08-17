package dockercli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/enegalan/calf/backend/internal/config"
)

const (
	shellMarkerBegin = "# calf docker cli"
	shellMarkerEnd   = "# end calf docker cli"
)

// EnsureShellCompletions writes docker completion files and a PATH snippet into the user shell rc.
func EnsureShellCompletions() error {
	binDir, err := config.BinDir()
	if err != nil {
		return err
	}
	compDir, err := config.CompletionsDir()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return fmt.Errorf("create bin dir: %w", err)
	}
	if err := os.MkdirAll(compDir, 0o755); err != nil {
		return fmt.Errorf("create completions dir: %w", err)
	}

	dockerBin, err := exec.LookPath("docker")
	if err != nil {
		return fmt.Errorf("docker CLI not found")
	}
	if err := writeCompletion(dockerBin, compDir, "zsh"); err != nil {
		return err
	}
	if err := writeCompletion(dockerBin, compDir, "bash"); err != nil {
		return err
	}

	snippet := shellSnippet(binDir, compDir)
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	for _, name := range []string{".zshrc", ".bashrc"} {
		if err := upsertShellBlock(filepath.Join(home, name), snippet); err != nil {
			return err
		}
	}
	return nil
}

// RemoveShellCompletions strips the calf PATH/completion block from shell rc files.
func RemoveShellCompletions() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	for _, name := range []string{".zshrc", ".bashrc"} {
		if err := removeShellBlock(filepath.Join(home, name)); err != nil {
			return err
		}
	}
	return nil
}

// writeCompletion runs `docker completion <shell>` into the completions directory.
func writeCompletion(dockerBin, compDir, shell string) error {
	out, err := exec.Command(dockerBin, "completion", shell).Output()
	if err != nil {
		return fmt.Errorf("docker completion %s: %w", shell, err)
	}
	name := "_docker"
	if shell == "bash" {
		name = "docker"
	}
	path := filepath.Join(compDir, name)
	if err := os.WriteFile(path, out, 0o644); err != nil {
		return fmt.Errorf("write %s completion: %w", shell, err)
	}
	return nil
}

// shellSnippet returns the rc block that prepends calf bin and loads completions.
func shellSnippet(binDir, compDir string) string {
	return strings.Join([]string{
		shellMarkerBegin,
		`export PATH="` + binDir + `:$PATH"`,
		`if [ -d "` + compDir + `" ]; then`,
		`  fpath=("` + compDir + `" $fpath)`,
		`  if [ -n "$BASH_VERSION" ] && [ -f "` + filepath.Join(compDir, "docker") + `" ]; then`,
		`    . "` + filepath.Join(compDir, "docker") + `"`,
		`  fi`,
		`fi`,
		shellMarkerEnd,
	}, "\n") + "\n"
}

// upsertShellBlock replaces or appends the calf marker block in path.
func upsertShellBlock(path, snippet string) error {
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	body := string(data)
	next := replaceShellBlock(body, snippet)
	if next == body && strings.Contains(body, shellMarkerBegin) {
		return nil
	}
	return os.WriteFile(path, []byte(next), 0o644)
}

// removeShellBlock deletes the calf marker block from path when present.
func removeShellBlock(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	next := replaceShellBlock(string(data), "")
	if next == string(data) {
		return nil
	}
	return os.WriteFile(path, []byte(next), 0o644)
}

// replaceShellBlock swaps the marked region for snippet, or appends snippet when missing.
func replaceShellBlock(body, snippet string) string {
	start := strings.Index(body, shellMarkerBegin)
	if start < 0 {
		if snippet == "" {
			return body
		}
		if body != "" && !strings.HasSuffix(body, "\n") {
			body += "\n"
		}
		return body + snippet
	}
	end := strings.Index(body[start:], shellMarkerEnd)
	if end < 0 {
		return body[:start] + snippet
	}
	end = start + end + len(shellMarkerEnd)
	for end < len(body) && (body[end] == '\n' || body[end] == '\r') {
		end++
	}
	return body[:start] + snippet + body[end:]
}
