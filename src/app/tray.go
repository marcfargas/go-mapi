package main

import (
	_ "embed"

	"fyne.io/systray"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed assets/tray/tray-idle.ico
var trayIdleIcon []byte

//go:embed assets/tray/tray-error.ico
var trayErrorIcon []byte

func (a *App) startTray() {
	start, end := systray.RunWithExternalLoop(a.onTrayReady, func() {})
	start()
	a.trayEnd = end
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
