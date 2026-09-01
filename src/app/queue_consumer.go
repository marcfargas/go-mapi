package main

import (
	"context"
	"fmt"

	"github.com/marcfargas/go-mapi/internal/mapi"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// queueConsumer is the app-owned seam between the shared queue contract and
// the Wails event bridge. It deliberately has no dependency on a running
// interceptor: opening an empty per-user queue is a healthy startup state.
type queueConsumer struct {
	watcher *mapi.EmailWatcher
	bridge  *watcherBridge
}

func newQueueConsumer(ctx context.Context, dir string, onError func(error)) (*queueConsumer, error) {
	return newQueueConsumerWithEmitter(ctx, dir, onError, func(name string, data ...interface{}) {
		wruntime.EventsEmit(ctx, name, data...)
	})
}

func newQueueConsumerWithEmitter(ctx context.Context, dir string, onError func(error), emit func(string, ...interface{})) (*queueConsumer, error) {
	bridge := newWatcherBridgeWithEmitter(ctx, onError, emit)
	watcher, err := mapi.NewEmailWatcherWithValidator(dir, bridge, func(mail *mapi.MailMessage) error {
		result := mapi.EvaluateCompatibility(mail.InterceptorVersion, mapi.CounterpartRequirement{
			Component: "interceptor", MinInclusive: RequiredInterceptorMin, MaxExclusive: RequiredInterceptorMax,
		}, "update-interceptor")
		if result.Status != mapi.CompatibilityCompatible {
			return fmt.Errorf("interceptor version %q is %s; required >= %s", mail.InterceptorVersion, result.Status, RequiredInterceptorMin)
		}
		return nil
	})
	if err != nil {
		bridge.Close()
		return nil, fmt.Errorf("open queue: %w", err)
	}
	bridge.setSnapshotSource(watcher.Snapshot)
	if err := watcher.Start(); err != nil {
		watcher.Stop()
		bridge.Close()
		return nil, fmt.Errorf("start queue: %w", err)
	}
	return &queueConsumer{watcher: watcher, bridge: bridge}, nil
}

func (q *queueConsumer) Close() {
	if q == nil {
		return
	}
	q.watcher.Stop()
	q.bridge.Close()
}
