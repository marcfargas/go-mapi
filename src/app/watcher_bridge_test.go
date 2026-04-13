package main

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// noopEmitter is a test emitter that does nothing (safe with non-Wails context).
func noopEmitter(_ string, _ ...interface{}) {}

// countingEmitter returns an emitter that increments a counter.
func countingEmitter(count *int32) func(string, ...interface{}) {
	return func(_ string, _ ...interface{}) {
		atomic.AddInt32(count, 1)
	}
}

// Test 1: newWatcherBridgeWithEmitter constructs a bridge with a buffered channel.
func TestNewWatcherBridgeCreated(t *testing.T) {
	ctx := context.Background()
	b := newWatcherBridgeWithEmitter(ctx, nil, noopEmitter)
	if b == nil {
		t.Fatal("newWatcherBridgeWithEmitter returned nil")
	}
	if b.pending == nil {
		t.Fatal("bridge.pending channel is nil")
	}
	if cap(b.pending) != 1 {
		t.Errorf("bridge.pending channel capacity must be 1, got %d", cap(b.pending))
	}
	if b.done == nil {
		t.Fatal("bridge.done channel is nil")
	}
	b.Close()
}

// Test 2: OnQueueChanged does NOT block even when called 100× in a tight loop.
func TestOnQueueChangedNonBlocking(t *testing.T) {
	ctx := context.Background()
	b := newWatcherBridgeWithEmitter(ctx, nil, noopEmitter)
	defer b.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 100; i++ {
			b.OnQueueChanged(nil)
		}
	}()

	select {
	case <-done:
		// 100 calls completed without blocking.
	case <-time.After(200 * time.Millisecond):
		t.Error("OnQueueChanged blocked — 100 calls should complete immediately")
	}
}

// Test 3: Dispatcher coalesces — 1-slot drop policy means at most 1 pending signal at a time.
// Verifies that OnQueueChanged behaves as a signal-only channel (drop if full).
func TestDispatcherCoalesces(t *testing.T) {
	ctx := context.Background()

	// Block the dispatcher so pending slot fills up.
	dispatchBlocked := make(chan struct{})
	var emitCount int32
	b := newWatcherBridgeWithEmitter(ctx, nil, func(_ string, _ ...interface{}) {
		// Block until test unblocks us.
		<-dispatchBlocked
		atomic.AddInt32(&emitCount, 1)
	})
	defer b.Close()

	// First call: fills the 1-slot pending channel.
	b.OnQueueChanged(nil)
	// Subsequent calls: all drop silently because channel is full.
	for i := 0; i < 49; i++ {
		b.OnQueueChanged(nil)
	}

	// Unblock dispatcher — it should emit exactly once for this burst.
	close(dispatchBlocked)

	// Give dispatcher time to process.
	time.Sleep(50 * time.Millisecond)

	count := atomic.LoadInt32(&emitCount)
	// Due to the 1-slot drop policy, exactly 1 pending signal is in the channel.
	if count != 1 {
		t.Errorf("dispatcher should emit exactly 1 time for a blocked burst, got %d", count)
	}
}

// Test 4: OnError synchronously calls the injected onError callback.
func TestOnErrorCallsCallback(t *testing.T) {
	ctx := context.Background()
	var errReceived error
	b := newWatcherBridgeWithEmitter(ctx, func(e error) {
		errReceived = e
	}, noopEmitter)
	defer b.Close()

	testErr := errWatcherTest("test error")
	b.OnError(testErr)

	if errReceived == nil {
		t.Error("OnError did not call onError callback")
	}
	if errReceived.Error() != "test error" {
		t.Errorf("expected error 'test error', got %q", errReceived.Error())
	}
}

// errWatcherTest is a simple test error type.
type errWatcherTest string

func (e errWatcherTest) Error() string { return string(e) }

// Test 5: Close is idempotent — calling Close() twice must not panic.
func TestBridgeCloseIdempotent(t *testing.T) {
	ctx := context.Background()
	b := newWatcherBridgeWithEmitter(ctx, nil, noopEmitter)

	defer func() {
		if r := recover(); r != nil {
			t.Errorf("Close() panicked on second call: %v", r)
		}
	}()

	b.Close()
	b.Close() // Must not panic.
}

// Test 6: Close() stops the dispatcher — returns within 500ms.
func TestBridgeCloseStopsDispatcher(t *testing.T) {
	ctx := context.Background()
	var emitCount int32
	b := newWatcherBridgeWithEmitter(ctx, nil, countingEmitter(&emitCount))

	// Enqueue one signal.
	b.OnQueueChanged(nil)
	// Give dispatcher a moment to pick it up.
	time.Sleep(20 * time.Millisecond)

	// Close should return within 500ms.
	closeDone := make(chan struct{})
	go func() {
		b.Close()
		close(closeDone)
	}()

	select {
	case <-closeDone:
		// Close completed.
	case <-time.After(500 * time.Millisecond):
		t.Error("Close() did not return within 500ms")
	}
}

// Test 7: 100 concurrent OnQueueChanged callers + concurrent Close() must not panic or race.
func TestBridgeConcurrentCallsAndClose(t *testing.T) {
	ctx := context.Background()
	b := newWatcherBridgeWithEmitter(ctx, nil, noopEmitter)

	var wg sync.WaitGroup
	const goroutines = 100
	wg.Add(goroutines)
	for i := 0; i < goroutines; i++ {
		go func() {
			defer wg.Done()
			b.OnQueueChanged(nil)
		}()
	}

	// Concurrent close while senders are still running.
	go b.Close()

	wg.Wait()
	// Final close to drain any remaining goroutines.
	b.Close()
}
