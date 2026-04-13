package main

import (
	_ "embed"
	"runtime"

	"fyne.io/systray"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed assets/tray/tray-idle.ico
var trayIdleIcon []byte

//go:embed assets/tray/tray-error.ico
var trayErrorIcon []byte

// startTray launches the system tray on a dedicated OS thread.
//
// CRITICAL (Plan 03 fix): fyne.io/systray creates its hidden tray window on the goroutine
// that calls Register/Run. The Win32 message pump for that window MUST run on the same
// OS thread (Win32 dispatches WM_RBUTTONUP / WM_LBUTTONUP to the thread that owns the
// window's message queue). Using `RunWithExternalLoop` here was wrong: its `start()`
// spawns a fresh goroutine that pumps messages from a *different* OS thread, so right-
// click never reached `wt.wndProc`, and no menu appeared.
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
	systray.SetIcon(trayIdleIcon)
	systray.SetTooltip("go-mapi — watching for emails")

	// Left-click toggles window visibility (D-06).
	// fyne.io/systray v1.12.0 exposes SetOnTapped for left-click on Windows.
	systray.SetOnTapped(a.toggleWindow)

	mShow := systray.AddMenuItem("Show", "Open main window")
	systray.AddSeparator()
	mQuit := systray.AddMenuItem("Quit", "Exit go-mapi")

	logInfo("tray ready: menu items registered (Show, Quit)")

	go func() {
		for {
			select {
			case <-mShow.ClickedCh:
				a.showWindow()
			case <-mQuit.ClickedCh:
				wruntime.Quit(a.ctx)
				return
			}
		}
	}()
}

// toggleWindow shows the window if hidden/minimised, hides it if visible.
func (a *App) toggleWindow() {
	if wruntime.WindowIsNormal(a.ctx) {
		wruntime.WindowHide(a.ctx)
		return
	}
	a.showWindow()
}

func (a *App) showWindow() {
	wruntime.WindowShow(a.ctx)
	wruntime.WindowUnminimise(a.ctx)
	// Note: no WindowSetAlwaysOnTop — removed per REVIEWS LOW to avoid visual jarring.
	// WindowShow + WindowUnminimise is sufficient for raise-to-front on Windows.
}

// SetTrayError swaps the tray icon to the error variant and updates the tooltip.
// Called by Plan 03 (watcher startup failure) to signal a fatal pre-ready error.
func (a *App) SetTrayError(msg string) {
	systray.SetIcon(trayErrorIcon)
	systray.SetTooltip("go-mapi — " + msg)
}
