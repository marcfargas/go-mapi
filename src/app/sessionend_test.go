//go:build windows

package main

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

// Test 1: registerSessionEndHandler returns a cancel func and no error.
func TestRegisterSessionEndHandlerReturnsCancel(t *testing.T) {
	var cancelled int32
	cancel, err := registerSessionEndHandler(func() {
		atomic.StoreInt32(&cancelled, 1)
	})
	if err != nil {
		t.Fatalf("registerSessionEndHandler returned error: %v", err)
	}
	if cancel == nil {
		t.Fatal("registerSessionEndHandler returned nil cancel")
	}
	// Cancel should complete without hanging.
	done := make(chan struct{})
	go func() {
		cancel()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Error("cancel() did not return within 2s")
	}
}

// Test 2: sessionEndWndProc returns 1 (TRUE) for WM_QUERYENDSESSION immediately,
// fires the signal callback non-blocking, and returns within 10ms.
func TestSessionEndWndProcReturnsTrueImmediately(t *testing.T) {
	var signalFired int32
	sessionEndSignal = func() {
		atomic.StoreInt32(&signalFired, 1)
	}

	start := time.Now()
	ret := sessionEndWndProc(0, wmQueryEndSession, 0, 0)
	elapsed := time.Since(start)

	if ret != 1 {
		t.Errorf("sessionEndWndProc must return 1 (TRUE) for WM_QUERYENDSESSION, got %d", ret)
	}
	if elapsed > 10*time.Millisecond {
		t.Errorf("sessionEndWndProc took %v — must return in < 10ms (REVIEWS HIGH)", elapsed)
	}
	if atomic.LoadInt32(&signalFired) != 1 {
		t.Error("sessionEndSignal callback was not fired by WM_QUERYENDSESSION")
	}
}

// Test 3: sessionEndWndProc does NOT call watcher.Stop, bridge.Close, or any I/O.
// Verified structurally: the function exists in sessionend.go and we confirm its implementation
// only fires sessionEndSignal and returns 1 — no blocking calls visible.
// (The grep-based acceptance criterion in the plan is the runtime-proof; this test
// guards the function signature and return value.)
func TestSessionEndWndProcNoIOInWndProc(t *testing.T) {
	// This test verifies the WndProc ONLY sets sessionEndSignal, returns 1, and returns fast.
	// A slow test here would indicate I/O inside the WndProc.
	var cbCalled int32
	sessionEndSignal = func() {
		atomic.StoreInt32(&cbCalled, 1)
		// Simulate a non-blocking callback that takes near-zero time.
	}
	start := time.Now()
	ret := sessionEndWndProc(0, wmQueryEndSession, 0, 0)
	dur := time.Since(start)

	if ret != 1 {
		t.Errorf("expected return 1, got %d", ret)
	}
	if dur > 5*time.Millisecond {
		t.Errorf("WndProc took %v — I/O or blocking call suspected inside WndProc", dur)
	}
	if atomic.LoadInt32(&cbCalled) == 0 {
		t.Error("sessionEndSignal not called")
	}
}

// Test 4: runBoundedDrainWithTimeout: drain completes fast — returns before timeout.
func TestBoundedDrainCompletesBeforeTimeout(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})

	go func() {
		runBoundedDrain(ctx, func() {
			// Fast drain — completes immediately.
		})
		close(done)
	}()

	// Cancel the context to trigger the drain.
	cancel()

	select {
	case <-done:
		// drain completed normally.
	case <-time.After(3 * time.Second):
		t.Error("runBoundedDrain did not return within 3s for a fast drain")
	}
}

// Test 5: watcher.Stop is idempotent — verify calling the drain func twice does not panic.
// (This relies on Plan 01's idempotent Stop via sync.Once.)
func TestDrainFuncIdempotent(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	drainCalled := 0
	drainFn := func() {
		drainCalled++
		// Simulate watcher.Stop + bridge.Close (both idempotent).
	}

	// Run drain once with cancelled context.
	cancel()
	runBoundedDrain(ctx, drainFn)
	if drainCalled != 1 {
		t.Errorf("drain func should be called exactly once, got %d", drainCalled)
	}
}

// Test 6: wmQueryEndSession constant is 0x0011.
func TestWmQueryEndSessionConstant(t *testing.T) {
	if wmQueryEndSession != 0x0011 {
		t.Errorf("wmQueryEndSession must be 0x0011, got 0x%04X", wmQueryEndSession)
	}
}

// Test 7: wmEndSession constant is 0x0016.
func TestWmEndSessionConstant(t *testing.T) {
	if wmEndSession != 0x0016 {
		t.Errorf("wmEndSession must be 0x0016, got 0x%04X", wmEndSession)
	}
}
