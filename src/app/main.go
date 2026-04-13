package main

import (
	"embed"

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
		return
	}
	defer releaseSingleInstance()

	app := NewApp()

	err := wails.Run(&options.App{
		Title:             "go-mapi",
		Width:             480,
		Height:            600,
		MinWidth:          360,
		MinHeight:         400,
		Assets:            assets,
		OnStartup:         app.startup,
		OnShutdown:        app.shutdown,
		OnBeforeClose:     app.beforeClose,
		Bind:              []interface{}{app},
		HideWindowOnClose: true,
		StartHidden:       true,
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
