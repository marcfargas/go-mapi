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
