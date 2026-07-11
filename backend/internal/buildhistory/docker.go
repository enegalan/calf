package buildhistory

import (
	"context"

	"github.com/enegalan/calf/backend/internal/constants"
	"github.com/enegalan/calf/backend/internal/dockerexec"
)

// runDocker executes docker against the given unix socket with a bounded timeout.
func runDocker(ctx context.Context, socket string, args ...string) ([]byte, error) {
	runCtx, cancel := context.WithTimeout(ctx, constants.DockerCLITimeout)
	defer cancel()

	return dockerexec.Run(runCtx, socket, args...)
}
