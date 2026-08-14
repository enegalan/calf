package buildhistory

import (
	"context"
	"strings"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/dockerexec"
)

// Runner executes docker CLI arguments (without the leading "docker" token).
type Runner func(ctx context.Context, args ...string) ([]byte, error)

// SocketRunner returns a Runner that invokes the host docker CLI against socket.
func SocketRunner(socket string) Runner {
	return func(ctx context.Context, args ...string) ([]byte, error) {
		return runDocker(ctx, socket, args...)
	}
}

// runDocker executes docker against the given unix socket with a bounded timeout.
func runDocker(ctx context.Context, socket string, args ...string) ([]byte, error) {
	runCtx, cancel := context.WithTimeout(ctx, constants.DockerCLITimeout)
	defer cancel()

	return dockerexec.Run(runCtx, socket, args...)
}

// IsDockerUnreachable reports a docker CLI / vsock connect failure (EOF, ping, buildkit dial).
func IsDockerUnreachable(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	markers := []string{
		"error during connect",
		"unexpected eof",
		"driver not connecting",
		"cannot connect to the docker daemon",
		"connection refused",
	}
	for _, marker := range markers {
		if strings.Contains(message, marker) {
			return true
		}
	}
	return false
}
