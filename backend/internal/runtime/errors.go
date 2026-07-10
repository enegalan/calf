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

func emptyContainersIfStopped(ctx context.Context, statusFn func(context.Context) (Status, error), listFn func(context.Context) ([]Container, error)) ([]Container, error) {
	return emptyIfStopped(ctx, statusFn, listFn)
}

func emptyImagesIfStopped(ctx context.Context, statusFn func(context.Context) (Status, error), listFn func(context.Context) ([]Image, error)) ([]Image, error) {
	return emptyIfStopped(ctx, statusFn, listFn)
}

func emptyVolumesIfStopped(ctx context.Context, statusFn func(context.Context) (Status, error), listFn func(context.Context) ([]Volume, error)) ([]Volume, error) {
	return emptyIfStopped(ctx, statusFn, listFn)
}

func emptyNetworksIfStopped(ctx context.Context, statusFn func(context.Context) (Status, error), listFn func(context.Context) ([]Network, error)) ([]Network, error) {
	return emptyIfStopped(ctx, statusFn, listFn)
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
