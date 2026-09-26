//go:build !windows

package service

import "context"

func lockStateStore(_ *ProtectedStorage) (func(), error) {
	return func() {}, nil
}

func lockStateStoreBounded(_ context.Context, storage *ProtectedStorage) (func(), error) {
	return lockStateStore(storage)
}
