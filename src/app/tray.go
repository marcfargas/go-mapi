package main

import (
	_ "embed"
	"fmt"
	"runtime"

	"fyne.io/systray"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed assets/tray/tray-idle.ico
var trayIdleIcon []byte

//go:embed assets/tray/tray-error.ico
var trayErrorIcon []byte

//go:embed assets/tray/tray-has-queue.ico
var trayHasQueueIcon []byte

// trayState captures every input that determines tray icon + tooltip. A pure
// helper (computeTrayVisual) maps this to visuals; callers ONLY mutate state
// and signal the tray goroutine — they never touch systray.* directly.
//
// Design: D-16 tray icon priority + D-17 tooltip format + T-9-10 Win32 HWND
// affinity (systray.* must run on the tray goroutine that called systray.Run).
type trayState struct {
	Mode     string // "manual" | "auto-draft"
	Paused   bool
	SignedIn bool
	ErrorMsg string // non-empty → error state overrides everything (D-16)
	Count    int
}

// computeTrayVisual is a pure function — testable without a live systray.
//
// Priority per D-16: error > has-queue > idle.
// Tooltip per D-17: "go-mapi — {segment} — N pending" (error overrides to "go-mapi — <msg>").
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
	// D-16 icon selection: has-queue only when signed in AND count > 0.
	// Paused/signed-out states remain on idle icon (tooltip carries the state).
	if s.Count > 0 && s.SignedIn && !s.Paused {
		return trayHasQueueIcon, tooltip
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
	systray.AddSeparator()
	mQuit := systray.AddMenuItem("Quit", "Exit go-mapi")

	logInfo("tray ready: menu items registered (Show, Pause watching, Quit)")

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
		Mode:     a.getMode(),
		Paused:   a.isPaused(),
		SignedIn: a.auth != nil && a.auth.Status().Authenticated,
		ErrorMsg: a.getLastError(),
		Count:    0,
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
