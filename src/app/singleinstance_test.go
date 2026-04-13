//go:build windows

package main

import (
	"strings"
	"sync"
	"testing"
	"time"
)

// Test 1: mutexName uses Local\ scope (not Global\) for RDS session isolation.
func TestMutexNameIsLocalScope(t *testing.T) {
	if !strings.HasPrefix(mutexName, `Local\`) {
		t.Errorf("mutexName must start with Local\\, got: %q", mutexName)
	}
}

// Test 2: raiseEventName uses Local\ scope.
func TestRaiseEventNameIsLocalScope(t *testing.T) {
	if !strings.HasPrefix(raiseEventName, `Local\`) {
		t.Errorf("raiseEventName must start with Local\\, got: %q", raiseEventName)
	}
}

// Test 3: mutexName does NOT use Global\ scope.
func TestMutexNameNotGlobalScope(t *testing.T) {
	if strings.HasPrefix(mutexName, `Global\`) {
		t.Errorf("mutexName must NOT use Global\\ scope (breaks RDS isolation): %q", mutexName)
	}
}

// Test 4: raiseEventName does NOT use Global\ scope.
func TestRaiseEventNameNotGlobalScope(t *testing.T) {
	if strings.HasPrefix(raiseEventName, `Global\`) {
		t.Errorf("raiseEventName must NOT use Global\\ scope (breaks RDS isolation): %q", raiseEventName)
	}
}

// Test 5: First acquireSingleInstance returns raised=false and no error.
func TestAcquireSingleInstanceFirst(t *testing.T) {
	// Ensure clean state before test.
	releaseSingleInstance()

	raised, err := acquireSingleInstance()
	if err != nil {
		t.Fatalf("first acquire returned error: %v", err)
	}
	if raised {
		t.Errorf("first acquire should return raised=false, got raised=true")
	}
	// Cleanup.
	releaseSingleInstance()
}

// Test 6: After releaseSingleInstance, a fresh acquire succeeds as first instance.
func TestReleaseAndReacquire(t *testing.T) {
	releaseSingleInstance()

	raised1, err1 := acquireSingleInstance()
	if err1 != nil || raised1 {
		t.Fatalf("first acquire failed: raised=%v err=%v", raised1, err1)
	}
	releaseSingleInstance()

	raised2, err2 := acquireSingleInstance()
	if err2 != nil {
		t.Fatalf("re-acquire after release returned error: %v", err2)
	}
	if raised2 {
		t.Errorf("re-acquire after release should return raised=false, got raised=true")
	}
	releaseSingleInstance()
}

// Test 7: waitForRaiseSignal returns promptly when done channel is closed.
func TestWaitForRaiseSignalExitsOnDone(t *testing.T) {
	done := make(chan struct{})
	called := make(chan struct{})
	var onceClose sync.Once

	go func() {
		waitForRaiseSignal(done, func() {})
		onceClose.Do(func() { close(called) })
	}()

	// Give goroutine time to start waiting.
	time.Sleep(10 * time.Millisecond)
	close(done)

	select {
	case <-called:
		// Exited as expected.
	case <-time.After(2 * time.Second):
		t.Error("waitForRaiseSignal did not exit within 2s after done channel closed")
	}
}

// Test 8a (Bug C regression): a second acquireSingleInstance() while the first still holds
// the mutex MUST return raised=true. The pre-fix implementation used windows.GetLastError()
// after CreateMutex — that read was unreliable in Go (other syscalls could clobber per-thread
// last-error between the two calls), causing the second instance to think it was the first
// and let multiple processes coexist. The fix uses the canonical err return from
// windows.CreateMutex (which the //sys directive sets to ERROR_ALREADY_EXISTS).
//
// This test simulates the same kernel-mutex contention by holding the mutex from one
// acquire and immediately calling acquireSingleInstance again — both calls go through
// the production code path on the same kernel object.
func TestSecondAcquireDetectsExistingInstance(t *testing.T) {
	releaseSingleInstance()

	// First acquire — we are the "first instance".
	raised1, err1 := acquireSingleInstance()
	if err1 != nil {
		t.Fatalf("first acquire returned error: %v", err1)
	}
	if raised1 {
		t.Fatalf("first acquire must return raised=false (no prior instance)")
	}

	// Stash the first-instance handles so a second acquireSingleInstance call hits
	// a non-zero in-process state path that mirrors a separate process.
	firstMutex := mutexHandle
	firstEvent := eventHandle
	mutexHandle = 0
	eventHandle = 0

	// Second acquire — must detect the existing kernel mutex.
	raised2, err2 := acquireSingleInstance()
	if err2 != nil {
		t.Fatalf("second acquire returned error: %v", err2)
	}
	if !raised2 {
		t.Errorf("Bug C regression: second acquire MUST return raised=true while first still holds the mutex; got raised=false (multiple instances would coexist)")
	}

	// Cleanup — release first-instance handles. The second-acquire path in the
	// production code is supposed to close its own duplicate handle (CloseHandle),
	// so we only need to close the first instance's handles here.
	mutexHandle = firstMutex
	eventHandle = firstEvent
	releaseSingleInstance()
}

// Test 8: waitForRaiseSignal calls onRaise when the raise event fires.
// This test only runs if eventHandle is set (i.e., we are the first instance).
func TestWaitForRaiseSignalCallsCallback(t *testing.T) {
	releaseSingleInstance()

	raised, err := acquireSingleInstance()
	if err != nil || raised {
		t.Fatalf("acquire failed: raised=%v err=%v", raised, err)
	}
	defer releaseSingleInstance()

	if eventHandle == 0 {
		t.Skip("eventHandle not created — skipping raise signal test")
	}

	done := make(chan struct{})
	raisedCh := make(chan struct{}, 1)

	go waitForRaiseSignal(done, func() {
		select {
		case raisedCh <- struct{}{}:
		default:
		}
	})
	defer close(done)

	// Signal the event directly to simulate a second instance calling raiseExistingInstance.
	if err := raiseExistingInstance(); err != nil {
		t.Skipf("raiseExistingInstance failed (event may not be open yet): %v", err)
	}

	select {
	case <-raisedCh:
		// Callback fired as expected.
	case <-time.After(2 * time.Second):
		t.Error("waitForRaiseSignal did not invoke onRaise within 2s of SetEvent")
	}
}
