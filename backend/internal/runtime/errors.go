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

// ErrContainerNotFound is returned when a container ID does not exist in the engine.
var ErrContainerNotFound = errors.New("container not found")

// ErrContainerNotRunning is returned when an operation requires a running container.
var ErrContainerNotRunning = errors.New("container is not running")

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

// KeepLastList returns the live list on success, or the last known list when a
// live fetch fails. A brief engine blip must not look like zero containers.
func KeepLastList[T any](cached []T, live []T, err error) ([]T, error) {
	if err == nil {
		return live, nil
	}
	if len(cached) == 0 {
		return live, err
	}
	return append([]T(nil), cached...), nil
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
