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
	watcher          *mapi.EmailWatcher // initialized in startup (Task 3)
	bridge           *watcherBridge     // initialized in startup (Task 3)
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

	// Bounded async drain — runs on shutdownCtx cancel (either session end or normal shutdown).
	// Watcher and bridge are nil until Task 3; the nil guards below handle that.
	go runBoundedDrain(a.shutdownCtx, func() {
		if a.watcher != nil {
			a.watcher.Stop() // idempotent (Plan 01 Test 7)
		}
		if a.bridge != nil {
			a.bridge.Close() // idempotent (Task 3 Test 5)
		}
	})

	logInfo("startup complete (version %s)", Version)
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
	// Idempotency (Plan 01 Test 7 + Task 3 Test 5) makes double-stop safe anyway.
	logInfo("shutdown complete")
}

// beforeClose intercepts the window close button and hides the window instead
// of quitting — keeps the app alive in the system tray.
func (a *App) beforeClose(ctx context.Context) (prevent bool) {
	wruntime.WindowHide(ctx)
	return true
}

// GetQueue returns the current email queue. Returns nil until Task 3 wires the watcher.
func (a *App) GetQueue() []mapi.EmailWithId { return nil }
