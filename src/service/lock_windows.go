//go:build windows

package service

import (
	"context"
	"errors"
	"os"
	"time"

	"golang.org/x/sys/windows"
)

type ownedFileLock struct {
	file       *os.File
	overlapped windows.Overlapped
}

// tryOwnRunnerLock uses a kernel file lock, so owner death releases the
// exclusion without an expiry clock or another process removing a lock file.
func tryOwnRunnerLock(storage *ProtectedStorage) (*ownedFileLock, error) {
	return ownFileLock(storage, "runner.lock", true)
}

func ownStateLock(storage *ProtectedStorage) (*ownedFileLock, error) {
	return ownFileLock(storage, "state.lock", false)
}

func lockStateStore(storage *ProtectedStorage) (func(), error) {
	lock, err := ownStateLock(storage)
	if err != nil {
		return nil, err
	}
	return func() { _ = lock.Close() }, nil
}

func lockStateStoreBounded(ctx context.Context, storage *ProtectedStorage) (func(), error) {
	deadline := time.NewTimer(2 * time.Second)
	defer deadline.Stop()
	for {
		lock, err := ownFileLock(storage, "state.lock", true)
		if err == nil {
			return func() { _ = lock.Close() }, nil
		}
		if !errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
			return nil, err
		}
		pause := time.NewTimer(50 * time.Millisecond)
		select {
		case <-ctx.Done():
			pause.Stop()
			return nil, ctx.Err()
		case <-deadline.C:
			pause.Stop()
			return nil, errors.New("final uninstall state lock is busy")
		case <-pause.C:
		}
	}
}

func ownFileLock(storage *ProtectedStorage, name string, failImmediately bool) (*ownedFileLock, error) {
	if storage == nil || storage.access != privateStorage {
		return nil, errors.New("file lock requires protected state storage")
	}
	path, err := storage.child(name)
	if err != nil {
		return nil, err
	}
	if err := storage.platform.checkPath(storage.root, path, false); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0600)
	if err != nil {
		return nil, err
	}
	if err := storage.platform.checkPath(storage.root, path, true); err != nil {
		file.Close()
		return nil, err
	}
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() {
		file.Close()
		return nil, errors.New("runner lock is not a regular protected file")
	}
	named, err := os.Lstat(path)
	if err != nil || !os.SameFile(opened, named) {
		file.Close()
		return nil, errors.New("runner lock path changed during open")
	}
	lock := &ownedFileLock{file: file}
	flags := uint32(windows.LOCKFILE_EXCLUSIVE_LOCK)
	if failImmediately {
		flags |= windows.LOCKFILE_FAIL_IMMEDIATELY
	}
	err = windows.LockFileEx(windows.Handle(file.Fd()), flags, 0, 1, 0, &lock.overlapped)
	if err != nil {
		file.Close()
		return nil, err
	}
	return lock, nil
}

func (lock *ownedFileLock) Close() error {
	if lock == nil || lock.file == nil {
		return nil
	}
	err := windows.UnlockFileEx(windows.Handle(lock.file.Fd()), 0, 1, 0, &lock.overlapped)
	return errors.Join(err, lock.file.Close())
}
