package runtime

import (
	"context"
	"errors"
)

var ErrRuntimeNotRunning = errors.New("runtime is not running")
var ErrNetworkNotFound = errors.New("network not found")

func emptyContainersIfStopped(ctx context.Context, statusFn func(context.Context) (Status, error), listFn func(context.Context) ([]Container, error)) ([]Container, error) {
	status, err := statusFn(ctx)
	if err != nil {
		return nil, err
	}

	if status.State != StateRunning {
		return []Container{}, nil
	}

	return listFn(ctx)
}

func emptyImagesIfStopped(ctx context.Context, statusFn func(context.Context) (Status, error), listFn func(context.Context) ([]Image, error)) ([]Image, error) {
	status, err := statusFn(ctx)
	if err != nil {
		return nil, err
	}

	if status.State != StateRunning {
		return []Image{}, nil
	}

	return listFn(ctx)
}

func emptyVolumesIfStopped(ctx context.Context, statusFn func(context.Context) (Status, error), listFn func(context.Context) ([]Volume, error)) ([]Volume, error) {
	status, err := statusFn(ctx)
	if err != nil {
		return nil, err
	}

	if status.State != StateRunning {
		return []Volume{}, nil
	}

	return listFn(ctx)
}

func emptyNetworksIfStopped(ctx context.Context, statusFn func(context.Context) (Status, error), listFn func(context.Context) ([]Network, error)) ([]Network, error) {
	status, err := statusFn(ctx)
	if err != nil {
		return nil, err
	}

	if status.State != StateRunning {
		return []Network{}, nil
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
