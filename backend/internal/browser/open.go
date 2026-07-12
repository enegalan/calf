package browser

import (
	"fmt"
	"os/exec"
	"runtime"
)

// OpenURL launches the system default browser or URL handler for the given address.
func OpenURL(url string) error {
	if url == "" {
		return fmt.Errorf("url is empty")
	}

	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", url)
	case "linux":
		cmd = exec.Command("xdg-open", url)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	default:
		return fmt.Errorf("unsupported platform: %s", runtime.GOOS)
	}

	return cmd.Run()
}
