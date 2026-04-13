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
type watcherBridge struct {
	ctx       context.Context
	emitter   func(name string, data ...interface{})
	onError   func(err error)
	pending   chan struct{}
	done      chan struct{}
	closeOnce sync.Once
	getSnap   func() []mapi.EmailWithId
}

func newWatcherBridge(ctx context.Context, onError func(err error)) *watcherBridge {
	b := &watcherBridge{
		ctx:     ctx,
		emitter: func(name string, data ...interface{}) { wruntime.EventsEmit(ctx, name, data...) },
		onError: onError,
		pending: make(chan struct{}, 1),
		done:    make(chan struct{}),
	}
	go b.dispatch()
	return b
}

func (b *watcherBridge) setSnapshotSource(fn func() []mapi.EmailWithId) { b.getSnap = fn }

// OnQueueChanged implements mapi.WatcherCallback.
// Non-blocking: drops the signal if one is already pending (coalesce-on-burst).
// The snapshot parameter is ignored; the dispatcher re-fetches via getSnap (Pitfall §5:
// no EventsEmit on hot watcher paths — signal-only channel keeps bridge decoupled).
func (b *watcherBridge) OnQueueChanged(_ []mapi.EmailWithId) {
	select {
	case b.pending <- struct{}{}:
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
		}
	}
}

// Close is idempotent (sync.Once guards the channel close).
func (b *watcherBridge) Close() {
	b.closeOnce.Do(func() { close(b.done) })
}
