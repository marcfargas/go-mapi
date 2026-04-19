package main

import (
	"context"
	"fmt"
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

	// Pause state: session-only per D-15. sync.Mutex-guarded bool.
	// NOT persisted — resets on every app start to prevent silent "forgot-I-paused" failures.
	pauseMu sync.Mutex
	paused  bool

	// Settings: RWMutex-guarded. UI reads frequently (tooltip, mode toggle);
	// writes only on user mode-toggle click (single-writer invariant, D-13).
	settingsMu sync.RWMutex
	settings   AppSettings

	// Automode goroutine handle. Started in startup; stopped in shutdown.
	automode *automode

	// Backlog skip-set (D-10): emails that failed automode with errorCategory
	// "signed-out" during a signed-out window stay manual after re-auth.
	// In-memory only — NEVER persisted. Pruned on every queue-update to
	// release memory for emails the user manually drafted or dismissed.
	backlogSkipMu sync.Mutex
	backlogSkip   map[string]struct{}
}

// NewApp creates a new App instance.
func NewApp() *App {
	return &App{
		auth:        NewAuthManager(),
		backlogSkip: make(map[string]struct{}),
		settings:    AppSettings{Mode: defaultMode},
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

	// Phase 8: load persisted OAuth tokens and emit initial auth-changed.
	// Must run after a.ctx is cached (line 42) and after tray is started
	// (line 47) because SetTrayError is called from bootstrapAuth.
	a.bootstrapAuth()

	// Phase 9: load persisted settings (mode field, D-13).
	a.settingsMu.Lock()
	a.settings = loadSettings()
	a.settingsMu.Unlock()
	logInfo("settings loaded: mode=%s", a.settings.Mode)

	// Phase 9: start automode goroutine. Gated on mode + paused at drain time.
	// Wire pruneBacklogSkip after every queue-update emit (D-10: backlog cleanup).
	if a.bridge != nil {
		a.automode = newAutomode(a, a.bridge.AutomodeWake())
		a.automode.start()
		logInfo("automode started")

		a.bridge.SetAfterDispatch(func() {
			if a.watcher == nil {
				return
			}
			snap := a.watcher.Snapshot()
			currentIds := make(map[string]struct{}, len(snap))
			for _, e := range snap {
				currentIds[e.Id] = struct{}{}
			}
			a.pruneBacklogSkip(currentIds)
		})
	}

	logInfo("startup complete (version %s, watching %s)", Version, watchDir)
}

func (a *App) shutdown(ctx context.Context) {
	// Stop automode goroutine before cancelling shutdownCtx so any in-flight
	// draftOne call has a chance to observe context cancellation cleanly.
	if a.automode != nil {
		a.automode.stop()
	}
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

// --- Pause / mode / backlog helpers (D-10, D-14, D-15) ---

// isPaused returns the current session-only pause state.
func (a *App) isPaused() bool {
	a.pauseMu.Lock()
	defer a.pauseMu.Unlock()
	return a.paused
}

// SetPaused updates the session-only pause state and emits pause-changed.
// Does NOT persist (D-15). Exposed as a Wails binding in Plan 04 via
// PauseWatching() / ResumeWatching() wrappers.
func (a *App) SetPaused(v bool) {
	a.pauseMu.Lock()
	changed := a.paused != v
	a.paused = v
	a.pauseMu.Unlock()
	if changed && a.ctx != nil {
		wruntime.EventsEmit(a.ctx, "pause-changed", v)
	}
}

// getMode returns the current mode ("manual" or "auto-draft").
// Falls back to defaultMode if not yet loaded (pre-startup call).
func (a *App) getMode() string {
	a.settingsMu.RLock()
	defer a.settingsMu.RUnlock()
	if a.settings.Mode == "" {
		return defaultMode
	}
	return a.settings.Mode
}

// setMode updates the in-memory mode AND persists via saveSettings. Rejects
// values other than "manual" and "auto-draft". Must be called only from a
// Wails binding (UI thread) — single-writer invariant from settings.go (D-13).
// Wakes automode so it immediately re-checks mode when switching to "auto-draft".
func (a *App) setMode(mode string) error {
	if mode != "manual" && mode != "auto-draft" {
		return fmt.Errorf("setMode: invalid mode %q", mode)
	}
	a.settingsMu.Lock()
	a.settings.Mode = mode
	s := a.settings
	a.settingsMu.Unlock()
	if err := saveSettings(s); err != nil {
		return err
	}
	// Wake automode so it re-checks mode immediately if we just switched ON.
	// Non-blocking; harmless if automode is nil (pre-startup) or already idle.
	if a.bridge != nil {
		select {
		case a.bridge.automodeWake <- struct{}{}:
		default:
		}
	}
	return nil
}

// isBacklogSkipped reports whether an email id is in the D-10 backlog-skip set.
func (a *App) isBacklogSkipped(id string) bool {
	a.backlogSkipMu.Lock()
	defer a.backlogSkipMu.Unlock()
	_, ok := a.backlogSkip[id]
	return ok
}

// markBacklogSkipped adds id to the D-10 backlog-skip set. Called by automode
// on first invalid_grant so post-re-auth drains leave the row for manual review.
func (a *App) markBacklogSkipped(id string) {
	a.backlogSkipMu.Lock()
	defer a.backlogSkipMu.Unlock()
	a.backlogSkip[id] = struct{}{}
}

// pruneBacklogSkip removes entries whose ids are absent from currentIds. Called
// after each queue-update event (via bridge.afterDispatch) so dismissed or
// manually-drafted rows do not permanently occupy memory for the session lifetime.
func (a *App) pruneBacklogSkip(currentIds map[string]struct{}) {
	a.backlogSkipMu.Lock()
	defer a.backlogSkipMu.Unlock()
	for id := range a.backlogSkip {
		if _, ok := currentIds[id]; !ok {
			delete(a.backlogSkip, id)
		}
	}
}
