package main

import (
	"context"

	"github.com/marcfargas/go-mapi/internal/mapi"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// App is the main application struct that bridges Wails and the system tray.
type App struct {
	ctx              context.Context
	trayEnd          func()
	watcher          *mapi.EmailWatcher // initialized in startup
	bridge           *watcherBridge     // initialized in startup
	sessionEndCancel func()             // cancels the session-end message pump
	shutdownCtx      context.Context
	shutdownCancel   context.CancelFunc
}

// NewApp creates a new App instance.
func NewApp() *App { return &App{} }

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.shutdownCtx, a.shutdownCancel = context.WithCancel(context.Background())
	a.startTray()

	// Named-event raise dispatcher — wakes when second instance calls SetEvent.
	go waitForRaiseSignal(a.shutdownCtx.Done(), func() {
		a.showWindow()
	})

	// Session-end handler — WndProc signals shutdown context; drain goroutine handles cleanup.
	cancel, err := registerSessionEndHandler(func() {
		// Non-blocking: just cancel the context. Drain goroutine below does the real work.
		a.shutdownCancel()
	})
	if err != nil {
		logError("session-end handler: %v", err)
	}
	a.sessionEndCancel = cancel

	// Watcher fold-in (SHELL-06).
	watchDir := watcherDir()
	a.bridge = newWatcherBridge(ctx, func(e error) {
		// T-07-22: log infrastructure event only, not email content.
		logError("watcher error: %v", e)
		a.SetTrayError("watcher stopped")
	})
	w, watcherErr := mapi.NewEmailWatcher(watchDir, a.bridge)
	if watcherErr != nil {
		logError("watcher init: %v", watcherErr)
		a.SetTrayError("watcher init failed")
		wruntime.EventsEmit(a.ctx, "queue-error", watcherErr.Error())
	} else {
		a.watcher = w
		a.bridge.setSnapshotSource(a.watcher.Snapshot)
		go func() {
			if startErr := a.watcher.Start(); startErr != nil {
				logError("watcher start: %v", startErr)
				a.SetTrayError("watcher start failed")
				wruntime.EventsEmit(a.ctx, "queue-error", startErr.Error())
			}
		}()
	}

	// Bounded async drain — runs on shutdownCtx cancel (session end or normal shutdown).
	// Registered AFTER watcher + bridge exist so nil checks are not needed in most paths.
	go runBoundedDrain(a.shutdownCtx, func() {
		if a.watcher != nil {
			a.watcher.Stop() // idempotent (Plan 01 Test 7)
		}
		if a.bridge != nil {
			a.bridge.Close() // idempotent (sync.Once)
		}
	})

	logInfo("startup complete (version %s, watching %s)", Version, watchDir)
}

func (a *App) shutdown(ctx context.Context) {
	// Normal Wails shutdown path: cancel context (drain goroutine handles cleanup via runBoundedDrain).
	if a.shutdownCancel != nil {
		a.shutdownCancel()
	}
	if a.sessionEndCancel != nil {
		a.sessionEndCancel()
	}
	if a.trayEnd != nil {
		a.trayEnd()
	}
	// Note: direct watcher.Stop / bridge.Close calls are handled by runBoundedDrain.
	// Idempotency (Plan 01 Test 7 + sync.Once) makes double-stop safe anyway.
	logInfo("shutdown complete")
}

// beforeClose intercepts the window close button and hides the window instead
// of quitting — keeps the app alive in the system tray.
func (a *App) beforeClose(ctx context.Context) (prevent bool) {
	wruntime.WindowHide(ctx)
	return true
}

// GetQueue returns the live watcher snapshot. Returns nil if watcher is not yet started.
// Replaces the Plan 02 stub with the real watcher-backed query.
func (a *App) GetQueue() []mapi.EmailWithId {
	if a.watcher == nil {
		return nil
	}
	return a.watcher.Snapshot()
}
