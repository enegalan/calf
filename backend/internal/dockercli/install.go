package dockercli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/enegalan/calf/backend/internal/config"
)

// InstallCLI installs docker, docker-compose, and docker-buildx via Homebrew when available.
// It always prepends ~/.config/calf/bin to PATH in the current process after a successful brew install.
func InstallCLI() error {
	if _, err := exec.LookPath("brew"); err != nil {
		return fmt.Errorf("Homebrew is not installed; run: brew install docker docker-compose docker-buildx")
	}
	pkgs := []string{"docker", "docker-compose", "docker-buildx"}
	args := append([]string{"install"}, pkgs...)
	cmd := exec.Command("brew", args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(output))
		if msg == "" {
			return fmt.Errorf("brew install docker plugins: %w", err)
		}
		return fmt.Errorf("brew install docker plugins: %s", msg)
	}

	binDir, err := config.BinDir()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return fmt.Errorf("create bin dir: %w", err)
	}

	for _, name := range []string{"docker", "docker-compose", "docker-buildx"} {
		src, lookErr := exec.LookPath(name)
		if lookErr != nil {
			continue
		}
		dest := filepath.Join(binDir, name)
		_ = os.Remove(dest)
		if linkErr := os.Symlink(src, dest); linkErr != nil {
			return fmt.Errorf("symlink %s: %w", name, linkErr)
		}
	}

	if runtime.GOOS != "windows" {
		os.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	}
	_, _, _ = EnsureCLIPlugins()
	return nil
}
