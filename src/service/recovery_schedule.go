package service

import (
	"context"
	"log"
	"sync/atomic"
	"time"
)

func recoveryPollInterval() time.Duration {
	timers, present, err := loadMachineValidationTimers()
	if err == nil && present && timers.Heartbeat < 30*time.Second {
		return timers.Heartbeat
	}
	return 30 * time.Second
}

// recoveryOperation has one outstanding owner even when a native observation
// ignores cancellation. Polling and status publication never wait for it. A
// late result retains its cancelled prelaunch context and cannot authorize a
// new spawn; the slot is released only when that actual operation exits.
type recoveryOperation struct{ active atomic.Bool }

func (op *recoveryOperation) start(ctx context.Context, bound time.Duration, run func(context.Context) error) bool {
	if bound <= 0 || ctx.Err() != nil || !op.active.CompareAndSwap(false, true) {
		return false
	}
	go func() {
		defer op.active.Store(false)
		work, cancel := context.WithTimeout(ctx, bound)
		defer cancel()
		if err := run(work); err != nil {
			log.Printf("go-mapi readiness recovery: %v", err)
		}
	}()
	return true
}

func withRecoverySchedule(base Schedule, poll func(context.Context) (bool, error), run func(context.Context) error) Schedule {
	return ScheduleFunc(func(ctx context.Context) {
		ticker := time.NewTicker(recoveryPollInterval())
		defer ticker.Stop()
		runRecoverySchedule(ctx, base, ticker.C, poll, run)
	})
}

func runRecoverySchedule(ctx context.Context, base Schedule, ticks <-chan time.Time, poll func(context.Context) (bool, error), run func(context.Context) error) {
	go base.Run(ctx)
	var operation recoveryOperation
	observe := func() {
		// Poll/store time spends the same prelaunch allowance; it is not an
		// extra five seconds added after the accepted 30s scheduling window.
		launchBy := time.Now().Add(recoveryPrelaunchBound)
		observation, cancel := context.WithTimeout(ctx, recoveryCleanupBound)
		due, err := poll(observation)
		cancel()
		if err != nil {
			log.Printf("go-mapi recovery status: %v", err)
			return
		}
		if due {
			operation.start(ctx, time.Until(launchBy), run)
		}
	}
	observe()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticks:
			observe()
		}
	}
}
