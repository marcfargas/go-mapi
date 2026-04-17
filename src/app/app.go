package main

import (
	"context"
	"sync"
	"sync/atomic"

	"github.com/marcfargas/go-mapi/internal/mapi"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// App is the main application struct that bridges Wails and the system tray.
type App struct {
	ctx              context.Context
	trayEnd          func()
	watcher          *mapi.EmailWatcher // initialized in startup
	bridge           *watcherBridge     // initialized in startup
	auth             *AuthManager       // OAuth token lifecycle
	sessionEndCancel func()             // cancels the session-end message pump
	shutdownCtx      context.Context
	shutdownCancel   context.CancelFunc

	// visibilityMu guards `visible`. Read by the tray goroutine (toggleWindow)
	// and written by showWindow / hideWindow / beforeClose.
	visibilityMu sync.Mutex
	visible      bool

	// intentionalQuit is set true by the tray Quit menu BEFORE calling wruntime.Quit,
	// so beforeClose can distinguish a "quit-now" from "X button = hide-to-tray".
	// Read/written across goroutines — atomic for race safety.
	intentionalQuit atomic.Bool
}

// NewApp creates a new App instance.
func NewApp() *App {
	return &App{
		auth: NewAuthManager(),
	}
}

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.shutdownCtx, a.shutdownCancel = context.WithCancel(context.Background())
	// StartHidden: true → visible starts false. Mirror that here so toggleWindow
	// will WindowShow on the first left-click.
	a.setVisible(false)
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

// beforeClose runs when Wails is about to quit (X button OR wruntime.Quit).
// Returning true cancels the quit; returning false lets it proceed.
//
// We use this as the unified "should we hide-to-tray vs really quit" gate, so that:
//   - X button → hide-to-tray (intentionalQuit is false, default)
//   - Tray "Quit" menu → process exits (tray sets intentionalQuit=true before calling
//     wruntime.Quit, so this gate returns false and Wails terminates)
//
// HideWindowOnClose is intentionally NOT set in main.go — Wails would otherwise hide
// the window directly without invoking beforeClose, and we'd lose visibility tracking
// (Bug A) and the chance to gate the Quit menu (Bug B).
func (a *App) beforeClose(ctx context.Context) (prevent bool) {
	if a.intentionalQuit.Load() {
		// Tray Quit menu fired; let Wails terminate.
		return false
	}
	// X button (or any other quit attempt without intent): hide to tray.
	wruntime.WindowHide(ctx)
	a.setVisible(false)
	return true
}

// Visibility tracking helpers — read/written from the tray goroutine.
//
// Wails does not expose a WindowIsVisible runtime API on Windows (only IsNormal,
// IsMaximised, IsMinimised, IsFullscreen — none of which reflect WindowHide state).
// So we maintain visibility ourselves: setVisible is called whenever showWindow /
// hideWindow / beforeClose run, and toggleWindow consults isVisible() to decide.
func (a *App) setVisible(v bool) {
	a.visibilityMu.Lock()
	a.visible = v
	a.visibilityMu.Unlock()
}

func (a *App) isVisible() bool {
	a.visibilityMu.Lock()
	defer a.visibilityMu.Unlock()
	return a.visible
}

// requestQuit marks the quit as user-initiated (so beforeClose lets it through)
// and asks Wails to terminate. Called by the tray Quit menu.
func (a *App) requestQuit() {
	a.intentionalQuit.Store(true)
	wruntime.Quit(a.ctx)
}

// GetQueue returns the live watcher snapshot. Returns nil if watcher is not yet started.
// Replaces the Plan 02 stub with the real watcher-backed query.
func (a *App) GetQueue() []mapi.EmailWithId {
	if a.watcher == nil {
		return nil
	}
	return a.watcher.Snapshot()
}
