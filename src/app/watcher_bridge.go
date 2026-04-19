package main

import (
	"context"
	"sync"

	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

// watcherBridge implements mapi.WatcherCallback. Buffers snapshot-change signals in a 1-slot
// channel (replace-on-write) so bursts coalesce into a single EventsEmit call. The dispatcher
// goroutine drains the slot and calls EventsEmit off any watcher-held locks (Pitfall §5).
//
// Plan 03 adds a second 1-slot channel (automodeWake) fed by the same OnQueueChanged call.
// The two channels are independent consumers on the same watcher signal — Option (ii) from
// RESEARCH §4 — so UI queue-update latency is independent of Gmail API latency in automode.
type watcherBridge struct {
	ctx          context.Context
	emitter      func(name string, data ...interface{})
	onError      func(err error)
	pending      chan struct{} // drives queue-update EventsEmit (dispatcher consumer)
	automodeWake chan struct{} // wakes the automode goroutine (Plan 03 consumer)
	done         chan struct{}
	closeOnce    sync.Once
	getSnap      func() []mapi.EmailWithId
	afterDispatch func() // optional hook called after each queue-update emit (Plan 03 pruneBacklogSkip)
}

// newWatcherBridge creates a bridge backed by the Wails EventsEmit for the given context.
// onError is called synchronously from the watcher goroutine — must be non-blocking.
func newWatcherBridge(ctx context.Context, onError func(err error)) *watcherBridge {
	return newWatcherBridgeWithEmitter(ctx, onError, func(name string, data ...interface{}) {
		wruntime.EventsEmit(ctx, name, data...)
	})
}

// newWatcherBridgeWithEmitter creates a bridge with an injectable emitter. Used in tests
// to avoid calling the Wails runtime with a non-Wails context.
func newWatcherBridgeWithEmitter(ctx context.Context, onError func(err error), emitFn func(string, ...interface{})) *watcherBridge {
	b := &watcherBridge{
		ctx:          ctx,
		emitter:      emitFn,
		onError:      onError,
		pending:      make(chan struct{}, 1),
		automodeWake: make(chan struct{}, 1),
		done:         make(chan struct{}),
	}
	go b.dispatch()
	return b
}

func (b *watcherBridge) setSnapshotSource(fn func() []mapi.EmailWithId) { b.getSnap = fn }

// OnQueueChanged implements mapi.WatcherCallback.
// Non-blocking: drops the signal if one is already pending (coalesce-on-burst).
// The snapshot parameter is ignored; the dispatcher re-fetches via getSnap (Pitfall §5:
// no EventsEmit on hot watcher paths — signal-only channel keeps bridge decoupled).
//
// Plan 03 (RESEARCH §4 Option (ii)): feeds BOTH 1-slot signals so the dispatcher and
// the automode goroutine are independent consumers. A stuck Gmail API call in automode
// does NOT delay queue-update emits; the two channels coalesce bursts independently.
func (b *watcherBridge) OnQueueChanged(_ []mapi.EmailWithId) {
	select {
	case b.pending <- struct{}{}:
	default:
	}
	select {
	case b.automodeWake <- struct{}{}:
	default:
	}
}

// OnError implements mapi.WatcherCallback.
func (b *watcherBridge) OnError(err error) {
	if b.onError != nil {
		b.onError(err)
	}
}

func (b *watcherBridge) dispatch() {
	for {
		select {
		case <-b.done:
			return
		case <-b.pending:
			// Emit queue-update off the watcher goroutine path (Pitfall §5).
			b.emitter("queue-update")
			if b.afterDispatch != nil {
				b.afterDispatch()
			}
		}
	}
}

// AutomodeWake returns the receive-only wake channel for the automode goroutine
// (Plan 03). Each OnQueueChanged non-blocking-sends one signal; the 1-slot
// capacity coalesces bursts identically to the dispatcher path (RESEARCH §4 Option (ii)).
func (b *watcherBridge) AutomodeWake() <-chan struct{} {
	return b.automodeWake
}

// SetAfterDispatch registers an optional callback invoked after each queue-update
// emit in the dispatcher loop. Plan 03 uses this to prune the backlogSkip set
// (D-10) after every queue-update so dismissed/manually-drafted rows are freed.
// Must be called before Start (not concurrent-safe with dispatch).
func (b *watcherBridge) SetAfterDispatch(fn func()) {
	b.afterDispatch = fn
}

// Close is idempotent (sync.Once guards the channel close).
func (b *watcherBridge) Close() {
	b.closeOnce.Do(func() { close(b.done) })
}
