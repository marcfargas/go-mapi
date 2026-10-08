//go:build !windows

package service

import (
	"context"
	"sync"
	"time"
)

// Native production uses kernel locks. The portable store retains equivalent
// within-process serialization for reconstruction/concurrency regression tests.
var portableStateLocks sync.Map

func portableStateLock(storage *ProtectedStorage) *sync.Mutex {
	lock, _ := portableStateLocks.LoadOrStore(storage.root, &sync.Mutex{})
	return lock.(*sync.Mutex)
}
func lockStateStore(storage *ProtectedStorage) (func(), error) {
	lock := portableStateLock(storage)
	lock.Lock()
	return lock.Unlock, nil
}
func lockStateStoreBounded(ctx context.Context, storage *ProtectedStorage) (func(), error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	lock := portableStateLock(storage)
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if lock.TryLock() {
			return lock.Unlock, nil
		}
		timer := time.NewTimer(time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
}
