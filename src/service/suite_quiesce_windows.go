//go:build windows

package service

import (
	"context"
	"errors"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi/update"
)

// closeSuiteForPending linearizes closure before persisting the one absolute
// grace deadline under admission -> state.lock. A failed CAS leaves C closed.
func closeSuiteForPending(ctx context.Context, gate *SuiteAdmission, store *FileStateStore, expected PendingV1) (PendingV1, time.Time, error) {
	if expected.SKU != update.Suite || expected.Runner == nil {
		return PendingV1{}, time.Time{}, errors.New("suite closure lacks runner identity")
	}
	var next PendingV1
	var closedAt time.Time
	err := gate.withExclusive(ctx, func(lock *suiteAdmissionLock) error {
		if err := lock.write('C'); err != nil {
			return err
		}
		closedAt = time.Now()
		var err error
		next, err = store.SaveSuiteDrainDeadline(ctx, expected, closedAt)
		return err
	})
	return next, closedAt, err
}

func suiteQuiescer(gate *SuiteAdmission, store *FileStateStore, forceEnd *time.Time) func(context.Context, PendingV1) (PendingV1, error) {
	return func(ctx context.Context, pending PendingV1) (PendingV1, error) {
		closed, closedAt, err := closeSuiteForPending(ctx, gate, store, pending)
		if err != nil {
			return PendingV1{}, err
		}
		deadline := *closed.AppDrainDeadline
		if pending.AppDrainDeadline == nil {
			deadline = closedAt.Add(suiteGraceDuration)
		}
		graceEnd, bound := suiteDrainBounds(time.Now(), deadline)
		*forceEnd = bound
		if err := drainSuiteProcesses(ctx, graceEnd, *forceEnd); err != nil {
			return PendingV1{}, err
		}
		return closed, nil
	}
}

func confirmSuiteBeforeResume(ctx context.Context, gate *SuiteAdmission, pending PendingV1, forceEnd time.Time) error {
	if pending.SKU != update.Suite {
		return nil
	}
	if pending.AppDrainDeadline == nil || forceEnd.IsZero() {
		return errors.New("suite installer lacks durable drain authorization")
	}
	open, err := gate.IsOpen(ctx)
	if err != nil {
		return err
	}
	if open {
		return errors.New("suite admission reopened before installer resume")
	}
	return drainSuiteProcesses(ctx, time.Now(), forceEnd)
}
