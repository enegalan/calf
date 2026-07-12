package limavm

import "os"

// ShellEnv returns environment variables for limactl shell SSH sessions.
func ShellEnv() []string {
	return append(os.Environ(), "SSH=ssh -o ControlMaster=no -o ControlPath=none")
}
