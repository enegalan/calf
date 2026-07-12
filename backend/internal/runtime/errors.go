package runtime

import (
	"context"
	"errors"

	"github.com/enegalan/calf/backend/internal/constants"
)

// ErrRuntimeNotRunning is returned when the runtime is not running.
var ErrRuntimeNotRunning = errors.New("runtime is not running")

// ErrNetworkNotFound is returned when a network is not found.
var ErrNetworkNotFound = errors.New("network not found")

// emptyIfStopped runs listFn only when the runtime is running; otherwise returns an empty slice so list endpoints stay 200 while the VM is starting.
func emptyIfStopped[T any](
	ctx context.Context,
	statusFn func(context.Context) (Status, error),
	listFn func(context.Context) ([]T, error),
) ([]T, error) {
	status, err := statusFn(ctx)
	if err != nil {
		return nil, err
	}

	if status.State != State(constants.RuntimeStateRunning) {
		return []T{}, nil
	}

	return listFn(ctx)
}

// requireRunning returns ErrRuntimeNotRunning when the runtime is not in the running state.
func requireRunning(ctx context.Context, statusFn func(context.Context) (Status, error)) error {
	status, err := statusFn(ctx)
	if err != nil {
		return err
	}

	if status.State != State(constants.RuntimeStateRunning) {
		return ErrRuntimeNotRunning
	}

	return nil
}
