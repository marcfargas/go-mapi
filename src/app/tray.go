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
				// requestQuit sets intentionalQuit=true so beforeClose lets Wails
				// terminate (instead of routing back through hide-to-tray). Plan 03
				// Bug B fix: previously beforeClose unconditionally returned true,
				// so wruntime.Quit was always cancelled and the menu did nothing.
				logInfo("quit requested via tray menu")
				a.requestQuit()
				return
			}
		}
	}()
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

// SetTrayError swaps the tray icon to the error variant and updates the tooltip.
// Called by Plan 03 (watcher startup failure) to signal a fatal pre-ready error.
func (a *App) SetTrayError(msg string) {
	systray.SetIcon(trayErrorIcon)
	systray.SetTooltip("go-mapi — " + msg)
}
