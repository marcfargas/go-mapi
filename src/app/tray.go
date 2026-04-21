package main

import (
	_ "embed"
	"fmt"
	"runtime"
	"time"

	"fyne.io/systray"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed assets/tray/tray-idle.ico
var trayIdleIcon []byte

//go:embed assets/tray/tray-error.ico
var trayErrorIcon []byte

//go:embed assets/tray/tray-has-queue.ico
var trayHasQueueIcon []byte

//go:embed assets/tray/tray-update.ico
var trayUpdateIcon []byte

// trayState captures every input that determines tray icon + tooltip. A pure
// helper (computeTrayVisual) maps this to visuals; callers ONLY mutate state
// and signal the tray goroutine — they never touch systray.* directly.
//
// Design: D-16 tray icon priority + D-17 tooltip format + T-9-10 Win32 HWND
// affinity (systray.* must run on the tray goroutine that called systray.Run).
//
// Phase 11: UpdateAvailable is an explicit tray visual signal — when true and
// no higher-priority state wins (error > has-queue > update > idle), the tray
// surfaces a distinct icon variant AND appends an "Update available" marker
// to the tooltip so the transition is concretely testable.
type trayState struct {
	Mode            string // "manual" | "auto-draft"
	Paused          bool
	SignedIn        bool
	ErrorMsg        string // non-empty → error state overrides everything (D-16)
	Count           int
	UpdateAvailable bool // Phase 11 — notify-only update signal (REL-04)
}

// computeTrayVisual is a pure function — testable without a live systray.
//
// Icon priority (highest first, D-16 + Phase 11):
//   error > has-queue > update-available > idle
//
// Tooltip (D-17 + Phase 11):
//   "go-mapi — {segment} — N pending"
//   • error path overrides to "go-mapi — <msg>"
//   • when UpdateAvailable (and no error), " • Update available" is appended
//     so the tray transition is observable even when the icon variant
//     cannot be visually distinguished from has-queue.
//
// Segment priority (highest first): error > paused > signed-out > mode.
func computeTrayVisual(s trayState) (icon []byte, tooltip string) {
	if s.ErrorMsg != "" {
		return trayErrorIcon, "go-mapi — " + s.ErrorMsg
	}
	// D-17 segment selection: paused > signed-out > mode.
	segment := "Manual"
	switch {
	case s.Paused:
		segment = "Paused"
	case !s.SignedIn:
		segment = "Signed out"
	case s.Mode == "auto-draft":
		segment = "Auto-draft"
	}
	tooltip = fmt.Sprintf("go-mapi — %s — %d pending", segment, s.Count)
	if s.UpdateAvailable {
		tooltip += " • Update available"
	}
	// D-16 icon selection: has-queue only when signed in AND count > 0.
	// Paused/signed-out states remain on idle icon (tooltip carries the state).
	if s.Count > 0 && s.SignedIn && !s.Paused {
		return trayHasQueueIcon, tooltip
	}
	// Phase 11 — update-available lives below has-queue but above plain idle:
	// a stable "something requires attention" signal without overriding the
	// queue count view when work is pending.
	if s.UpdateAvailable {
		return trayUpdateIcon, tooltip
	}
	return trayIdleIcon, tooltip
}

// startTray launches the system tray on a dedicated OS thread.
//
// CRITICAL (Plan 03 fix `e8b95da`): fyne.io/systray creates its hidden tray window on the
// goroutine that calls Register/Run. The Win32 message pump for that window MUST run on the
// same OS thread (Win32 dispatches WM_RBUTTONUP / WM_LBUTTONUP to the thread that owns the
// window's message queue). Using `RunWithExternalLoop` here was wrong: its `start()` spawns
// a fresh goroutine that pumps messages from a *different* OS thread, so right-click never
// reached `wt.wndProc`, and no menu appeared.
//
// Fix: spawn one dedicated goroutine, LockOSThread, and call `systray.Run` (which does
// Register + nativeLoop on the same locked thread). `Run` blocks until `systray.Quit()`,
// so it lives on its own goroutine for the lifetime of the app.
func (a *App) startTray() {
	a.trayEnd = func() { systray.Quit() }
	go func() {
		runtime.LockOSThread()
		// systray.Run blocks here, pumping messages on this locked thread.
		systray.Run(a.onTrayReady, func() {})
	}()
}

func (a *App) onTrayReady() {
	// Initial visuals — start with signed-out idle state; refreshTrayVisual will
	// reconcile once startup settles (auth bootstrap, settings load, watcher start).
	icon, tip := computeTrayVisual(trayState{Mode: "manual", SignedIn: false, Count: 0})
	systray.SetIcon(icon)
	systray.SetTooltip(tip)

	// Left-click toggles window visibility (D-06).
	// fyne.io/systray v1.12.0 exposes SetOnTapped for left-click on Windows.
	systray.SetOnTapped(a.toggleWindow)

	mShow := systray.AddMenuItem("Show", "Open main window")
	// Pause watching (D-14): suppresses toasts + halts automode; watcher keeps running.
	// Session-only (D-15): label resets on restart. Placed between Show and Quit.
	mPause := systray.AddMenuItem("Pause watching", "Silences toasts and auto-draft; queue still collecting")

	// Phase 11 — update status rows + actions (D-05, D-06, D-07).
	// Placement: between Pause and Quit, with a separator above and below to
	// visually group "update" as a distinct section.
	systray.AddSeparator()
	mVersion := systray.AddMenuItem(formatUpdateCurrentVersionLabel(a.GetUpdateState()), "")
	mVersion.Disable()
	mLastChecked := systray.AddMenuItem(
		formatUpdateLastCheckedLabel(a.GetUpdateState(), time.Now().UTC()),
		"",
	)
	mLastChecked.Disable()
	// D-05: toggle lives in the tray context menu, writes through App settings.
	mToggleUpdates := systray.AddMenuItemCheckbox(
		"Check for updates",
		"Background check every 24 hours and on startup",
		a.isUpdateChecksEnabled(),
	)
	// D-06: manual action bypasses the 24h cadence.
	mCheckNow := systray.AddMenuItem("Check for updates now", "Check GitHub for a newer release")
	// The "Download" row only lights up when an update is available (D-03 + REL-04):
	// clicking it opens the GitHub release page in the user's browser. It NEVER
	// launches an installer, quits-and-installs, or replaces the running binary.
	mDownload := systray.AddMenuItem("Download update", "Open the latest release page on GitHub")
	if !a.snapshotUpdateAvailable() {
		mDownload.Hide()
	}

	systray.AddSeparator()
	mQuit := systray.AddMenuItem("Quit", "Exit go-mapi")

	logInfo("tray ready: menu items registered (Show, Pause watching, update status + toggle + check-now, Quit)")

	go func() {
		for {
			select {
			case <-mShow.ClickedCh:
				a.showWindow()
			case <-mPause.ClickedCh:
				// Toggle pause state. Both paths emit pause-changed → signalTrayRefresh
				// → refresh loop updates tooltip. Label flip here is view-only (T-7).
				if a.isPaused() {
					a.ResumeWatching()
					mPause.SetTitle("Pause watching")
				} else {
					a.PauseWatching()
					mPause.SetTitle("Resume watching")
				}
			case <-mToggleUpdates.ClickedCh:
				// Flip the opt-out flag. setUpdateChecksEnabled writes through the
				// App settings path (D-05 — no second persistence path) and signals
				// tray refresh. The Checked() visual flip is view-only and must stay
				// on this goroutine.
				next := !mToggleUpdates.Checked()
				if err := a.setUpdateChecksEnabled(next); err != nil {
					logError("tray: setUpdateChecksEnabled(%v): %v", next, err)
					break
				}
				if next {
					mToggleUpdates.Check()
				} else {
					mToggleUpdates.Uncheck()
				}
			case <-mCheckNow.ClickedCh:
				// D-06 manual action. Runs on this tray goroutine but the fetch
				// work itself is dispatched to a fresh goroutine so we never block
				// the systray message pump on a network call.
				go a.runTrayManualUpdateCheck(a.shutdownCtx)
			case <-mDownload.ClickedCh:
				// REL-04 + D-03: open browser to the release page. Never launch
				// an installer or quit-and-install. The helper handles the
				// URL choice and the silent-failure-on-browser-open case.
				a.handleUpdateDownloadAction()
			case <-mQuit.ClickedCh:
				// requestQuit sets intentionalQuit=true so beforeClose lets Wails
				// terminate (instead of routing back through hide-to-tray). Plan 03
				// Bug B fix: previously beforeClose unconditionally returned true,
				// so wruntime.Quit was always cancelled and the menu did nothing.
				logInfo("quit requested via tray menu")
				a.requestQuit()
				return
			case <-a.trayRefreshCh:
				// Signal from app goroutine — refresh icon + tooltip on this
				// LockOSThread-ed goroutine (T-9-10: Win32 HWND affinity).
				a.refreshTrayVisual()
				// Refresh the update status rows in place so the menu reflects
				// the latest snapshot without rebuilding items. D-07 surface.
				snap := a.GetUpdateState()
				mVersion.SetTitle(formatUpdateCurrentVersionLabel(snap))
				mLastChecked.SetTitle(formatUpdateLastCheckedLabel(snap, time.Now().UTC()))
				if snap.Enabled {
					mToggleUpdates.Check()
				} else {
					mToggleUpdates.Uncheck()
				}
				if snap.UpdateAvailable {
					mDownload.Show()
				} else {
					mDownload.Hide()
				}
			case <-a.shutdownCtx.Done():
				return
			}
		}
	}()
}

// refreshTrayVisual reads current app state and updates systray icon + tooltip.
//
// MUST run only on the tray goroutine (triggered by trayRefreshCh receive in the
// onTrayReady goroutine loop). Any other caller violates LockOSThread / Win32
// HWND affinity — see T-9-10 in the plan threat model.
func (a *App) refreshTrayVisual() {
	state := trayState{
		Mode:            a.getMode(),
		Paused:          a.isPaused(),
		SignedIn:        a.auth != nil && a.auth.Status().Authenticated,
		ErrorMsg:        a.getLastError(),
		Count:           0,
		UpdateAvailable: a.snapshotUpdateAvailable(),
	}
	if a.watcher != nil {
		state.Count = len(a.watcher.Snapshot())
	}
	icon, tip := computeTrayVisual(state)
	systray.SetIcon(icon)
	systray.SetTooltip(tip)
}

// toggleWindow shows the window if hidden, hides it if visible.
//
// Bug A fix: previously used wruntime.WindowIsNormal which returns true for any
// non-min/non-max/non-fullscreen state — INCLUDING when the window is hidden. So
// after WindowHide, IsNormal stayed true and a second left-click hid again instead
// of showing. We now track visibility in App.visible and consult that.
func (a *App) toggleWindow() {
	if a.isVisible() {
		a.hideWindow()
		return
	}
	a.showWindow()
}

func (a *App) showWindow() {
	wruntime.WindowShow(a.ctx)
	wruntime.WindowUnminimise(a.ctx)
	a.setVisible(true)
	// Note: no WindowSetAlwaysOnTop — removed per REVIEWS LOW to avoid visual jarring.
	// WindowShow + WindowUnminimise is sufficient for raise-to-front on Windows.
}

func (a *App) hideWindow() {
	wruntime.WindowHide(a.ctx)
	a.setVisible(false)
}

// SetTrayError signals a fatal error that overrides other tray state (D-16 priority 1).
// Thread-safe — fans out via trayRefreshCh; actual systray update runs on the tray
// goroutine via refreshTrayVisual (T-9-10 HWND affinity fix).
//
// Replaces the old direct systray.SetIcon/SetTooltip calls (which violated the
// LockOSThread invariant when called from app goroutines).
func (a *App) SetTrayError(msg string) {
	a.setLastError(msg)
}

// SetTrayIdle clears the error state. Icon + tooltip revert to computed values
// based on mode/paused/signed-in/count. The `msg` argument is kept in the
// signature to avoid breaking existing call sites; it is intentionally unused —
// the tooltip is now fully computed by refreshTrayVisual via computeTrayVisual.
func (a *App) SetTrayIdle(_ string) {
	a.setLastError("")
}
