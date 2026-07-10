package runtime

import (
	"context"
	"errors"
)

var ErrRuntimeNotRunning = errors.New("runtime is not running")
var ErrNetworkNotFound = errors.New("network not found")

func emptyIfStopped[T any](
	ctx context.Context,
	statusFn func(context.Context) (Status, error),
	listFn func(context.Context) ([]T, error),
) ([]T, error) {
	status, err := statusFn(ctx)
	if err != nil {
		return nil, err
	}

	if status.State != StateRunning {
		return []T{}, nil
	}

	return listFn(ctx)
}

func requireRunning(ctx context.Context, statusFn func(context.Context) (Status, error)) error {
	status, err := statusFn(ctx)
	if err != nil {
		return err
	}

	if status.State != StateRunning {
		return ErrRuntimeNotRunning
	}

	return nil
}
