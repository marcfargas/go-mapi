package main

import (
	"embed"
	"os"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

//go:embed all:frontend/dist
var assets embed.FS

var Version = "0.0.0-dev" // overridden via -ldflags "-X main.Version=..."

func main() {
	raised, siErr := acquireSingleInstance()
	if siErr != nil {
		logError("single-instance: %v", siErr)
		// Fail-open: proceed to run anyway so the user doesn't lose access.
	}
	if raised {
		// Another instance owns the mutex; we signaled its named event. Exit now.
		// Use os.Exit to be explicit: no Wails init, no defers needing to run, fastest path out.
		logInfo("second instance detected — signalled first instance, exiting")
		os.Exit(0)
	}
	defer releaseSingleInstance()

	app := NewApp()

	// Note: HideWindowOnClose is intentionally NOT set. With it true, Wails routes the X
	// button straight to f.WindowHide() without invoking OnBeforeClose — that bypasses our
	// visibility tracking (Bug A) and the intentionalQuit gate (Bug B). Instead we let
	// the X button fire OnBeforeClose, and our beforeClose hides the window AND updates
	// visibility (return true = prevent the actual close).
	err := wails.Run(&options.App{
		Title:         "go-mapi",
		Width:         480,
		Height:        600,
		MinWidth:      360,
		MinHeight:     400,
		Assets:        assets,
		OnStartup:     app.startup,
		OnShutdown:    app.shutdown,
		OnBeforeClose: app.beforeClose,
		Bind:          []interface{}{app},
		StartHidden:   true,
		Windows: &windows.Options{
			WebviewIsTransparent: false,
			WindowIsTranslucent:  false,
			DisableWindowIcon:    false,
		},
	})
	if err != nil {
		println("Error:", err.Error())
	}
}
