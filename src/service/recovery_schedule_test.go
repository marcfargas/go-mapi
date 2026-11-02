package service

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestRecoveryOperationCancellationDoesNotPermitOverlapOrLateSpawn(t *testing.T) {
	var op recoveryOperation
	entered, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var calls, spawns atomic.Int32
	run := func(ctx context.Context) error {
		calls.Add(1)
		close(entered)
		<-release
		defer close(done)
		if err := ctx.Err(); err != nil {
			return err
		}
		spawns.Add(1)
		return nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if !op.start(ctx, 10*time.Millisecond, run) {
		t.Fatal("first start refused")
	}
	<-entered
	time.Sleep(20 * time.Millisecond)
	for range 10 {
		if op.start(ctx, time.Second, run) {
			t.Fatal("timed-out native call overlapped")
		}
	}
	close(release)
	<-done
	if spawns.Load() != 0 || calls.Load() != 1 {
		t.Fatalf("late operation spawned=%d calls=%d", spawns.Load(), calls.Load())
	}
}
func TestRecoveryPollingIndependentOfSlowHealthDiscoveryAndReadiness(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ticks := make(chan time.Time)
	polls := make(chan int, 20)
	started := make(chan struct{})
	release := make(chan struct{})
	exited := make(chan struct{})
	var calls atomic.Int32
	base := ScheduleFunc(func(ctx context.Context) { <-ctx.Done() })
	go func() {
		defer close(exited)
		runRecoverySchedule(ctx, base, ticks, func(context.Context) (bool, error) { polls <- 1; return true, nil }, func(ctx context.Context) error { calls.Add(1); close(started); <-release; return nil })
	}()
	<-polls
	<-started
	for range 5 {
		ticks <- time.Now()
		select {
		case <-polls:
		case <-time.After(time.Second):
			t.Fatal("Await stalled publication")
		}
	}
	if calls.Load() != 1 {
		t.Fatal("overlapping recovery operations")
	}
	close(release)
	cancel()
	<-exited
}
func TestRecoveryProductionSchedulingAllPollAlignmentsAndReconstruction(t *testing.T) {
	// Execute the scheduling owner with injected tick instants, including a
	// reconstructed owner after backoff. Callback work consumes its full 30s
	// allowance in the injected clock; no short fixture timer supplies this SLA.
	for alignment := 0; alignment < 30; alignment++ {
		for _, restart := range []bool{false, true} {
			failure := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC).Add(time.Duration(alignment) * time.Second)
			due := failure.Add(15 * time.Minute)
			now := due.Truncate(30 * time.Second)
			if restart {
				now = now.Add(-30 * time.Second)
			}
			ctx, cancel := context.WithCancel(context.Background())
			ticks := make(chan time.Time)
			observed := make(chan struct{})
			spawned := make(chan time.Time, 1)
			done := make(chan struct{})
			go func() {
				defer close(done)
				runRecoverySchedule(ctx, ScheduleFunc(func(ctx context.Context) { <-ctx.Done() }), ticks, func(context.Context) (bool, error) {
					ready := !now.Before(due)
					observed <- struct{}{}
					return ready, nil
				}, func(context.Context) error { spawned <- now.Add(recoveryPrelaunchBound); return nil })
			}()
			<-observed
			for now.Before(due) {
				now = now.Add(30 * time.Second)
				ticks <- now
				<-observed
			}
			select {
			case spawn := <-spawned:
				if spawn.Sub(failure) > 16*time.Minute {
					t.Fatalf("alignment%d restart%v missed bound: %v", alignment, restart, spawn.Sub(failure))
				}
			case <-time.After(time.Second):
				t.Fatal("due recovery never started")
			}
			cancel()
			<-done
		}
	}
}
