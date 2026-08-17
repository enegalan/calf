package dockercli

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/enegalan/calf/backend/internal/config"
)

// DefaultSocketStatus reports whether /var/run/docker.sock currently points at calf.
type DefaultSocketStatus struct {
	Enabled bool   `json:"enabled"`
	Path    string `json:"path"`
	Target  string `json:"target,omitempty"`
	Hint    string `json:"hint,omitempty"`
}

// ProbeDefaultSocket reports the state of the classic Docker socket path.
func ProbeDefaultSocket(calfSocket string) DefaultSocketStatus {
	status := DefaultSocketStatus{Path: config.DefaultSystemDockerSocket}
	if runtime.GOOS == "windows" {
		status.Hint = "The classic Unix docker.sock path is not used on Windows."
		return status
	}
	info, err := os.Lstat(config.DefaultSystemDockerSocket)
	if err != nil {
		status.Hint = "Your password may be required once."
		return status
	}
	if SocketPointsAtCalf(config.DefaultSystemDockerSocket, calfSocket) {
		status.Enabled = true
		link, _ := os.Readlink(config.DefaultSystemDockerSocket)
		status.Target = link
		if status.Target == "" {
			status.Target = config.DefaultSystemDockerSocket
		}
		return status
	}
	target := config.DefaultSystemDockerSocket
	if info.Mode()&os.ModeSymlink != 0 {
		resolved, resErr := filepath.EvalSymlinks(config.DefaultSystemDockerSocket)
		if resErr == nil {
			target = resolved
		}
	}
	status.Target = target
	status.Hint = "Another Docker engine is using it."
	return status
}

// EnableDefaultSocket creates /var/run/docker.sock as a symlink to calfSocket (admin prompt on macOS).
func EnableDefaultSocket(calfSocket string) error {
	if runtime.GOOS == "windows" {
		return fmt.Errorf("default docker.sock is Unix-only")
	}
	abs, err := filepath.Abs(calfSocket)
	if err != nil {
		return err
	}
	if SocketPointsAtCalf(config.DefaultSystemDockerSocket, abs) {
		_ = os.Chmod(abs, 0o666)
		return nil
	}
	if err := os.Chmod(abs, 0o666); err != nil {
		return fmt.Errorf("chmod calf socket: %w", err)
	}
	script := "ln -sfn " + shellSingleQuote(abs) + " " + shellSingleQuote(config.DefaultSystemDockerSocket)
	return runAdmin(script)
}

// DisableDefaultSocket removes /var/run/docker.sock when it is a symlink to calf.
func DisableDefaultSocket(calfSocket string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	status := ProbeDefaultSocket(calfSocket)
	if !status.Enabled {
		return nil
	}
	script := "rm -f " + shellSingleQuote(config.DefaultSystemDockerSocket)
	return runAdmin(script)
}

// PrivilegedHelperSock is the unix socket the root helper listens on.
const PrivilegedHelperSock = "/var/run/calf-helper.sock"

// RequestPrivilegedForward asks the root helper to listen on TCP port and splice to target.
func RequestPrivilegedForward(port int, target string) error {
	if port < 1 || port > 1023 {
		return fmt.Errorf("privileged port out of range")
	}
	conn, err := net.Dial("unix", PrivilegedHelperSock)
	if err != nil {
		return fmt.Errorf("privileged helper not running (enable Privileged ports in Settings): %w", err)
	}
	defer conn.Close()
	enc := json.NewEncoder(conn)
	if err := enc.Encode(map[string]any{"op": "tcp", "port": port, "target": target}); err != nil {
		return err
	}
	var resp struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		return fmt.Errorf("privileged helper response: %w", err)
	}
	if !resp.OK {
		if resp.Error == "" {
			return fmt.Errorf("privileged helper refused port %d", port)
		}
		return fmt.Errorf("privileged helper: %s", resp.Error)
	}
	return nil
}

// InstallPrivilegedHelper installs a LaunchDaemon (macOS) or sudoers-friendly unit that runs bin helper.
func InstallPrivilegedHelper(bin string) error {
	if strings.TrimSpace(bin) == "" {
		return fmt.Errorf("helper binary path is required")
	}
	abs, err := filepath.Abs(bin)
	if err != nil {
		return err
	}
	switch runtime.GOOS {
	case "darwin":
		plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.calf.helper</string>
  <key>ProgramArguments</key>
  <array>
    <string>` + abs + `</string>
    <string>helper</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
`
		script := "printf '%s' " + shellSingleQuote(plist) + " > /Library/LaunchDaemons/dev.calf.helper.plist && launchctl bootstrap system /Library/LaunchDaemons/dev.calf.helper.plist >/dev/null 2>&1 || launchctl load -w /Library/LaunchDaemons/dev.calf.helper.plist"
		return runAdmin(script)
	case "linux":
		script := "install -m 0755 " + shellSingleQuote(abs) + " /usr/local/sbin/calf-helper && " +
			shellSingleQuote(abs) + " helper >/tmp/calf-helper.log 2>&1 &"
		return runAdmin(script)
	default:
		return fmt.Errorf("privileged helper is not supported on this platform")
	}
}

// runAdmin runs script with an administrator prompt on macOS, or sudo on Linux.
func runAdmin(script string) error {
	switch runtime.GOOS {
	case "darwin":
		cmd := exec.Command("osascript", "-e", "do shell script "+strconv.Quote(script)+" with administrator privileges")
		output, err := cmd.CombinedOutput()
		if err != nil {
			msg := strings.TrimSpace(string(output))
			if msg == "" {
				return fmt.Errorf("admin helper: %w", err)
			}
			return fmt.Errorf("admin helper: %s", msg)
		}
		return nil
	case "linux":
		cmd := exec.Command("sudo", "-n", "sh", "-c", script)
		output, err := cmd.CombinedOutput()
		if err != nil {
			msg := strings.TrimSpace(string(output))
			if msg == "" {
				return fmt.Errorf("sudo helper: %w", err)
			}
			return fmt.Errorf("sudo helper: %s", msg)
		}
		return nil
	default:
		return fmt.Errorf("privileged helper is not supported on this platform")
	}
}

// shellSingleQuote wraps s for a POSIX shell.
func shellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
