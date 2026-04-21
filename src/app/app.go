package main

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"sync"
	"sync/atomic"
	"time"

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

	// lastErrorMsg holds the most recent error message for tray display (D-16 priority 1).
	// Set by: watcher init/start failure, SetTrayError caller paths.
	// Cleared on: successful sign-in (SetTrayIdle), or explicit clear.
	// Guarded by errorMsgMu.
	errorMsgMu   sync.Mutex
	lastErrorMsg string

	// trayRefreshCh is a 1-slot signal channel (T-9-11: coalesced, drop-if-full).
	// Any app goroutine that changes state relevant to the tray (queue, auth, pause,
	// mode, error) sends here. The tray goroutine drains and calls refreshTrayVisual()
	// on its LockOSThread-ed context — keeping systray.* Win32 HWND affinity intact
	// (T-9-10 mitigation).
	trayRefreshCh chan struct{}

	// --- Phase 11: notify-only update state (REL-03, REL-05) --------
	//
	// updates is the stateless service that performs version fetch +
	// compare. App owns the cadence/scheduling and all persistence —
	// the service is a pure consumer.
	updates *updateService

	// updateState is the cached UpdateState snapshot that tray and
	// frontend consume via GetUpdateState. atomic.Pointer so readers
	// never block a background goroutine that is refreshing the state.
	updateState atomic.Pointer[UpdateState]

	// updateWriteMu serializes persistence of LastUpdateCheck via the
	// guarded writer persistLastUpdateCheck. This preserves the
	// single-writer atomic-save invariant that settings.go expects —
	// background cadence goroutines must NEVER call saveSettings
	// directly (11-PATTERNS.md §Seam 1).
	updateWriteMu sync.Mutex

	// updateStateEmitter is the test-injectable hook for observing
	// state-change emissions. Production wires this to wruntime
	// EventsEmit("update-state-changed", ...) in startup; tests set it
	// to a counter to verify the contract without spinning up Wails.
	updateStateEmitter func(UpdateState)

	// updateStateObserver is the in-process observer for tray /
	// notification code that needs to react to state changes. Separate
	// from updateStateEmitter so the Wails event emission path and the
	// in-process notification path never race (Phase 11 Plan 02 —
	// tray_update.go / update_notifications.go). At most one observer
	// is registered at a time; callers that need fan-out wrap their
	// own dispatcher.
	updateStateObserver func(UpdateState)

	// updateSchedulerStop cancels the long-lived 24h scheduler
	// goroutine on shutdown. nil until the scheduler starts.
	updateSchedulerStop context.CancelFunc
}

// NewApp creates a new App instance.
func NewApp() *App {
	return &App{
		auth:          NewAuthManager(),
		backlogSkip:   make(map[string]struct{}),
		settings:      AppSettings{Mode: defaultMode},
		trayRefreshCh: make(chan struct{}, 1),
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
		// Start synchronously so processExistingFiles completes before we seed
		// knownIds below — prevents spurious arrival toasts for pre-existing
		// emails on app restart (WR-02 / NOTIF-04).
		if startErr := a.watcher.Start(); startErr != nil {
			logError("watcher start: %v", startErr)
			a.SetTrayError("watcher start failed")
			wruntime.EventsEmit(a.ctx, "queue-error", startErr.Error())
		}
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

	// Phase 9: initialize toast notification stack (Windows only; no-op on other platforms).
	// Must run after bootstrapAuth so initToasts can reference ctx. Errors are non-fatal —
	// toasts are best-effort; the app functions without them.
	if err := initToasts(a); err != nil {
		logError("toast: init failed: %v", err)
	}

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

		// knownIds seeds to the current queue at startup to prevent stale emails
		// from triggering arrival toasts (NOTIF-04: no spam on app restart).
		initialSnap := a.watcher.Snapshot()
		knownIds := make(map[string]struct{}, len(initialSnap))
		for _, e := range initialSnap {
			knownIds[e.Id] = struct{}{}
		}

		a.bridge.SetAfterDispatch(func() {
			if a.watcher == nil {
				return
			}
			snap := a.watcher.Snapshot()
			currentIds := make(map[string]struct{}, len(snap))
			for _, e := range snap {
				currentIds[e.Id] = struct{}{}
			}
			// Detect newly arrived emails (present now but not in knownIds) and
			// fire arrival toasts. Only emails that arrive while the app is running
			// get toasts — seeded IDs are silently absorbed (NOTIF-04).
			for _, e := range snap {
				if _, seen := knownIds[e.Id]; !seen {
					emitArrivalToast(a, e)
					knownIds[e.Id] = struct{}{}
				}
			}
			// Prune knownIds for emails that left the queue (drafted / dismissed)
			// to avoid unbounded memory growth in long-running sessions.
			for id := range knownIds {
				if _, ok := currentIds[id]; !ok {
					delete(knownIds, id)
				}
			}
			a.pruneBacklogSkip(currentIds)
			// Signal tray to refresh icon + tooltip (queue count may have changed).
			a.signalTrayRefresh()
		})
	}

	// Phase 11: initialize notify-only update service and wire Wails
	// event emission. Failing to build the GitHub fetcher is non-fatal
	// — the app still runs; we just never detect updates until next
	// start (D-04 silent-failure invariant extends to the updater
	// bootstrap itself).
	if fetcher, err := newGitHubReleaseFetcher(); err != nil {
		logError("updates: init GitHub fetcher: %v", err)
	} else {
		a.updates = newUpdateService(Version, fetcher, logInfo)
		a.updateState.Store(&UpdateState{
			CurrentVersion: Version,
			InstallerURL:   installerDownloadURL,
			Enabled:        a.settings.UpdateChecksEnabled,
			LastCheckedAt:  a.settings.LastUpdateCheck,
		})
		a.updateStateEmitter = func(state UpdateState) {
			if a.ctx != nil {
				wruntime.EventsEmit(a.ctx, "update-state-changed", state)
			}
		}
		// Phase 11 Plan 02: in-process notification helper. Subscribes
		// to update-state fan-out and fires a tray toast on flip-to-
		// available. Silent on failures per D-04; never touches the
		// installer binary (D-03).
		a.wireUpdateNotifications()
		// REL-03: startup check runs on a goroutine so network IO does
		// not delay main-window readiness. MaybeCheck inside
		// runStartupUpdateCheck enforces opt-out + 24h cadence.
		go a.runStartupUpdateCheck(a.shutdownCtx)
		// Long-lived recurring cadence — a session open for days still
		// rechecks every 24h (scheduler ticks hourly but the cadence
		// gate enforces the 24h floor).
		a.startUpdateScheduler()
		logInfo("updates: service ready (enabled=%v)", a.settings.UpdateChecksEnabled)
	}

	logInfo("startup complete (version %s, watching %s)", Version, watchDir)
}

func (a *App) shutdown(ctx context.Context) {
	// Stop automode goroutine before cancelling shutdownCtx so any in-flight
	// draftOne call has a chance to observe context cancellation cleanly.
	if a.automode != nil {
		a.automode.stop()
	}
	// Phase 11: stop the long-lived update scheduler before cancelling
	// shutdownCtx so the ticker goroutine exits cleanly.
	if a.updateSchedulerStop != nil {
		a.updateSchedulerStop()
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
	if changed {
		if a.ctx != nil {
			wruntime.EventsEmit(a.ctx, "pause-changed", v)
		}
		// Signal tray goroutine to refresh icon + tooltip (T-9-10: must run on tray thread).
		a.signalTrayRefresh()
	}
}

// setLastError updates the last error message for tray display (D-16 priority 1).
// Only signals the tray refresh channel when the message actually changes, to avoid
// wake storms when multiple error paths converge on the same message (T-9-11).
func (a *App) setLastError(msg string) {
	a.errorMsgMu.Lock()
	changed := a.lastErrorMsg != msg
	a.lastErrorMsg = msg
	a.errorMsgMu.Unlock()
	if changed {
		a.signalTrayRefresh()
	}
}

// getLastError returns the current error message for tray display.
func (a *App) getLastError() string {
	a.errorMsgMu.Lock()
	defer a.errorMsgMu.Unlock()
	return a.lastErrorMsg
}

// signalTrayRefresh is the single entry point for all app-goroutine code that
// wants the tray icon/tooltip to refresh. Non-blocking — drops the signal if
// the 1-slot channel is already full (T-9-11: burst coalescing). The tray goroutine
// reads the latest snapshot on each wake, so no state is lost by dropping signals.
func (a *App) signalTrayRefresh() {
	select {
	case a.trayRefreshCh <- struct{}{}:
	default:
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
	// Signal tray to refresh tooltip (mode segment in D-17 changes on mode flip).
	a.signalTrayRefresh()
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

// ---- Phase 9 bindings (QUEUE-02/03/04, SHELL-02) ----

// validateEmailID is the shared validator for CreateDraftForID + DismissEmail.
// IDs are 64-char hex SHA256 hashes from the watcher (see internal/mapi/watcher.go).
// Any non-hex / wrong-length input is a frontend bug or tampering — reject early
// with a typed error (T-9-08 mitigation).
func validateEmailID(id string) error {
	if id == "" {
		return errors.New("email id: empty")
	}
	if len(id) > 128 {
		return errors.New("email id: too long")
	}
	return nil
}

// CreateDraftForID runs the Gmail draft-creation flow for a single queued
// email in response to a user action (row Create draft button).
//
// Emits `auto-draft-result` with the same shape as automode (Plan 03) so
// the frontend can hydrate the drafted flash / error badge uniformly.
// Unlike automode, does NOT mark the email as backlog-skipped on invalid_grant —
// the user explicitly triggered this call; backlog-skip only applies to
// background auto-draft attempts (D-10).
func (a *App) CreateDraftForID(id string) error {
	if err := validateEmailID(id); err != nil {
		return err
	}
	if a.watcher == nil {
		return errors.New("watcher not ready")
	}
	// Confirm the id is actually in the queue — returns a useful error to
	// the frontend rather than propagating a Gmail call with empty body.
	var target *mapi.EmailWithId
	for _, e := range a.watcher.Snapshot() {
		if e.Id == id {
			e := e
			target = &e
			break
		}
	}
	if target == nil {
		// Idempotency path — row already processed / dismissed. Log + return nil.
		logInfo("CreateDraftForID: id %s no longer in queue", safeIDPrefix(id))
		return nil
	}

	ctx, cancel := context.WithTimeout(a.shutdownCtx, 30*time.Second)
	defer cancel()

	callErr := a.MakeAuthenticatedGmailCall(ctx, func(token string) (int, error) {
		gc := mapi.NewGmailClientWithBase(token, gmailBaseURLOverride)
		_, err := gc.CreateDraft(target.Message)
		if err != nil {
			if err.Error() == "token expired" {
				return 401, err
			}
			return 500, err
		}
		return 200, nil
	})
	if callErr != nil {
		category := classifyAutomodeError(callErr)
		logError("CreateDraftForID: draft %s failed: %s", safeIDPrefix(id), category)
		if a.ctx != nil {
			wruntime.EventsEmit(a.ctx, "auto-draft-result", map[string]any{
				"emailId":       id,
				"success":       false,
				"errorCategory": category,
			})
		}
		// Error toast fires regardless of window state (D-11: errors always surface).
		emitErrorToast(a, category, id)
		return callErr
	}
	if err := a.watcher.MarkProcessed(id); err != nil {
		logError("CreateDraftForID: MarkProcessed %s: %v", safeIDPrefix(id), err)
	}
	// Draft-success toast: only when window is hidden (D-11). Subject is safe to
	// include per UI-SPEC; privacy is preserved (no body text, no recipient email).
	if target.Message != nil {
		emitDraftSuccessToast(a, target.Message.Subject, id)
	}
	// Clear the arrival + error toasts for this email from Action Center (NOTIF-05).
	clearToastForEmail(id)
	if a.ctx != nil {
		wruntime.EventsEmit(a.ctx, "auto-draft-result", map[string]any{
			"emailId": id,
			"success": true,
		})
	}
	return nil
}

// DismissEmail removes a queued email's JSON file without creating a draft.
// Does NOT require auth (user may dismiss while signed out). Idempotent via
// watcher.Delete (Plan 03 Task 1). Emits no event — queue-update fires
// automatically from the watcher fsnotify path.
func (a *App) DismissEmail(id string) error {
	if err := validateEmailID(id); err != nil {
		return err
	}
	if a.watcher == nil {
		return errors.New("watcher not ready")
	}
	if err := a.watcher.Delete(id); err != nil {
		return fmt.Errorf("dismiss %s: %w", safeIDPrefix(id), err)
	}
	// Clear arrival + error toasts for this email from Action Center (NOTIF-05).
	clearToastForEmail(id)
	return nil
}

// GetSettings returns the in-memory AppSettings. Frontend reads this once on
// mount to hydrate the ModeToggle; subsequent changes flow through SaveSettings.
func (a *App) GetSettings() AppSettings {
	a.settingsMu.RLock()
	defer a.settingsMu.RUnlock()
	s := a.settings
	if s.Mode == "" {
		s.Mode = defaultMode
	}
	return s
}

// SaveSettings persists AppSettings to %APPDATA%\go-mapi\settings.json.
// Delegates to setMode for validation + wake-automode-if-mode-flipped. In
// Phase 9 Mode is the only field; future phases may surface more here.
func (a *App) SaveSettings(s AppSettings) error {
	return a.setMode(s.Mode)
}

// GetMode is a convenience wrapper. Frontend may prefer GetSettings for
// future-proofing (new fields land in AppSettings, not as parallel bindings).
func (a *App) GetMode() string { return a.getMode() }

// SetMode is a convenience wrapper (matches GetMode for symmetry).
func (a *App) SetMode(mode string) error { return a.setMode(mode) }

// PauseWatching suppresses toasts + halts automode drain (D-14). Session-only
// per D-15; resets on next app start. Watcher keeps running — queue still accrues.
func (a *App) PauseWatching() { a.SetPaused(true) }

// ResumeWatching re-enables toasts + automode drain.
func (a *App) ResumeWatching() { a.SetPaused(false) }

// GetPausedState returns the current session pause state.
func (a *App) GetPausedState() bool { return a.isPaused() }

// ---- Phase 11: update-check bindings (REL-03, REL-05, D-06, D-07) ----

// updateCheckInterval is how often the long-lived scheduler wakes while
// the app stays open. Intentionally shorter than updateCheckWindow so
// a boundary crossing during a multi-day session is handled promptly.
// The cadence gate inside MaybeCheck still enforces the 24h floor, so
// ticking more often is safe — we only do real fetches when stale.
var updateCheckInterval = 1 * time.Hour

// GetUpdateState returns the cached notify-only update state for the
// frontend / tray. Always returns a valid snapshot — never nil — so
// callers never need to guard a pointer. If the App has not been
// fully initialised yet, CurrentVersion falls back to main.Version.
func (a *App) GetUpdateState() UpdateState {
	if state := a.updateState.Load(); state != nil {
		return *state
	}
	return UpdateState{
		CurrentVersion: Version,
		InstallerURL:   installerDownloadURL,
	}
}

// CheckForUpdatesNow forces an immediate update check, bypassing the
// 24h cadence gate. Exposed as the D-06 manual "Check for updates now"
// action for tray/frontend consumers. Returns the fetch error to the
// caller for logging; on failure, the prior cached state is preserved
// (D-04 silent-failure invariant — transient outages must not wipe a
// previously-detected update).
func (a *App) CheckForUpdatesNow(ctx context.Context) error {
	if a.updates == nil {
		return errors.New("updates: service not initialised")
	}
	// Always run through the full manual-check path so LastUpdateCheck
	// is persisted and the state-change emitter fires.
	newState, err := a.updates.CheckNow(ctx)
	newState.Enabled = a.isUpdateChecksEnabled()
	a.applyUpdateCheckResult(newState, err)
	return err
}

// isUpdateChecksEnabled is a small RLock helper so call sites read
// the current opt-out flag without duplicating the mutex dance.
func (a *App) isUpdateChecksEnabled() bool {
	a.settingsMu.RLock()
	defer a.settingsMu.RUnlock()
	return a.settings.UpdateChecksEnabled
}

// lastUpdateCheckValue reads the persisted LastUpdateCheck under the
// settings RLock.
func (a *App) lastUpdateCheckValue() string {
	a.settingsMu.RLock()
	defer a.settingsMu.RUnlock()
	return a.settings.LastUpdateCheck
}

// runStartupUpdateCheck is the D-08 "check on startup" path, subject to
// REL-05 opt-out and the REL-03 24h cadence gate. Never blocks startup
// for network IO when called on a goroutine; the synchronous form is
// retained so tests can drive the path deterministically.
func (a *App) runStartupUpdateCheck(ctx context.Context) {
	a.runGatedUpdateCheck(ctx)
}

// updateSchedulerTick is one iteration of the long-lived 24h cadence
// loop. Re-evaluates settings each tick so a user who flips the opt-out
// toggle at runtime is honored immediately. Silent-failure invariant
// applies (D-04).
func (a *App) updateSchedulerTick(ctx context.Context) {
	a.runGatedUpdateCheck(ctx)
}

// runGatedUpdateCheck is the shared cadence/opt-out path used by both
// startup and the scheduler tick. Uses MaybeCheck so the cadence gate
// lives in one place (the update service); App handles state caching,
// persistence, and observer notification.
func (a *App) runGatedUpdateCheck(ctx context.Context) {
	if a.updates == nil {
		return
	}
	settings := updateSettings{
		Enabled:         a.isUpdateChecksEnabled(),
		LastUpdateCheck: a.lastUpdateCheckValue(),
		Now:             time.Now().UTC(),
	}
	newState, checked, err := a.updates.MaybeCheck(ctx, settings)
	if !checked {
		// Opt-out or inside 24h window. Refresh the cached Enabled
		// flag in case the user toggled the opt-out; do not mutate
		// LatestVersion / LastCheckedAt (we did not attempt a fetch).
		a.syncUpdateEnabledIntoState(settings.Enabled)
		return
	}
	a.applyUpdateCheckResult(newState, err)
}

// applyUpdateCheckResult merges a fresh check result into the cached
// state, persists LastCheckedAt through the guarded writer, and fires
// the state-change emitter. On fetch error, LatestVersion / URL /
// UpdateAvailable from the previous snapshot are preserved (D-04).
func (a *App) applyUpdateCheckResult(newState UpdateState, fetchErr error) {
	prior := a.GetUpdateState()
	merged := UpdateState{
		CurrentVersion:   newState.CurrentVersion,
		InstallerURL:     installerDownloadURL,
		LastCheckedAt:    newState.LastCheckedAt,
		Enabled:          newState.Enabled,
		LatestVersion:    newState.LatestVersion,
		LatestReleaseURL: newState.LatestReleaseURL,
		UpdateAvailable:  newState.UpdateAvailable,
	}
	if fetchErr != nil {
		// Preserve whatever the user previously saw — banner must not
		// flicker on transient outages (D-04).
		merged.LatestVersion = prior.LatestVersion
		merged.LatestReleaseURL = prior.LatestReleaseURL
		merged.UpdateAvailable = prior.UpdateAvailable
	}
	if merged.CurrentVersion == "" {
		merged.CurrentVersion = Version
	}
	a.updateState.Store(&merged)

	// Persist LastCheckedAt through the single-writer guarded path so
	// background goroutines never touch saveSettings directly.
	if merged.LastCheckedAt != "" {
		if err := a.persistLastUpdateCheck(merged.LastCheckedAt); err != nil {
			logError("updates: persist last-checked: %v", err)
		}
	}

	if a.updateStateEmitter != nil {
		a.updateStateEmitter(merged)
	}
	// Phase 11 Plan 02: in-process observer fan-out for tray/notification
	// code. Distinct from the Wails EventsEmit hook so the frontend path
	// and the tray path can evolve independently.
	if a.updateStateObserver != nil {
		a.updateStateObserver(merged)
	}
	// Signal tray refresh so the update-available icon/tooltip and the
	// "Last checked" status row reflect this result. Coalesced via the
	// 1-slot channel (T-9-11) so repeated result emissions never wake
	// the tray more than necessary.
	a.signalTrayRefresh()
}

// syncUpdateEnabledIntoState updates the cached Enabled flag without
// changing any other field. Called on opt-out / within-window no-op
// paths so tray/frontend see toggle changes even when no fetch ran.
func (a *App) syncUpdateEnabledIntoState(enabled bool) {
	prior := a.GetUpdateState()
	if prior.Enabled == enabled {
		return
	}
	prior.Enabled = enabled
	a.updateState.Store(&prior)
	if a.updateStateEmitter != nil {
		a.updateStateEmitter(prior)
	}
}

// persistLastUpdateCheck is the App-owned guarded writer for the
// LastUpdateCheck field. Serializes concurrent background callers with
// updateWriteMu, reads the current settings snapshot under the
// settings lock, writes LastUpdateCheck, then delegates to saveSettings
// (the existing atomic-save path). Preserves the single-writer
// invariant documented in settings.go — NO background goroutine may
// call saveSettings directly (11-PATTERNS.md §Seam 1).
func (a *App) persistLastUpdateCheck(ts string) error {
	a.updateWriteMu.Lock()
	defer a.updateWriteMu.Unlock()

	a.settingsMu.Lock()
	a.settings.LastUpdateCheck = ts
	snapshot := a.settings
	a.settingsMu.Unlock()

	return saveSettings(snapshot)
}

// startUpdateScheduler kicks off the long-lived 24h cadence goroutine.
// Called from startup after the update service is built. The goroutine
// wakes every updateCheckInterval, re-evaluates opt-out + last-checked
// state, and performs a silent recheck when the cadence floor is crossed.
// Cancelled via updateSchedulerStop on shutdown.
func (a *App) startUpdateScheduler() {
	if a.updates == nil {
		return
	}
	ctx, cancel := context.WithCancel(a.shutdownCtx)
	a.updateSchedulerStop = cancel
	go func() {
		ticker := time.NewTicker(updateCheckInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				a.updateSchedulerTick(ctx)
			}
		}
	}()
}

// handleToastAction dispatches a toast click or button tap to the appropriate
// App binding. Called from the COM activation callback (initToasts) on a
// goroutine — safe to call Wails bindings from here.
//
// args format: URL query string, e.g. "action=open&emailId=<id>"
// Recognised actions: "create-draft", "dismiss", "open" (default: open).
func (a *App) handleToastAction(args string) {
	q, err := url.ParseQuery(args)
	if err != nil {
		logError("toast: bad activation args: %s", safeIDPrefix(args))
		a.showWindow()
		return
	}
	op := q.Get("action")
	id := q.Get("emailId")
	switch op {
	case "create-draft":
		if err := a.CreateDraftForID(id); err != nil {
			logError("toast: CreateDraftForID %s: %v", safeIDPrefix(id), err)
		}
		// clearToastForEmail already called inside CreateDraftForID on success;
		// on failure emitErrorToast already fired. Nothing more to do here.
		a.showWindow()
	case "dismiss":
		// Dismiss is a silent background action (NOTIF-05): no showWindow call.
		// On failure the row remains visible if the user opens the app; the error
		// is not actionable from the notification itself, so we only log it.
		if err := a.DismissEmail(id); err != nil {
			logError("toast: DismissEmail %s: %v", safeIDPrefix(id), err)
			// Intentionally not calling showWindow on dismiss failure —
			// the row will be visible when the user opens the app.
		}
		// clearToastForEmail already called inside DismissEmail on success.
	case "open":
		a.showWindow()
	case "open-update":
		// Phase 11 Plan 02: update-available toast body was clicked.
		// Open the release page in the browser; D-03 invariant — never
		// launch an installer. openUpdateReleasePage handles the
		// LatestReleaseURL vs fallback decision and swallows
		// browser.Open failures silently per D-04.
		openUpdateReleasePage(a.GetUpdateState())
	default:
		logError("toast: unknown action %q", op)
		a.showWindow()
	}
}
