package main

import (
	"context"

	"github.com/marcfargas/go-mapi/internal/mapi"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// App is the main application struct that bridges Wails and the system tray.
type App struct {
	ctx     context.Context
	trayEnd func()
	watcher *mapi.EmailWatcher // Plan 03 initializes
}

// NewApp creates a new App instance.
func NewApp() *App { return &App{} }

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.startTray()
}

func (a *App) shutdown(ctx context.Context) {
	if a.trayEnd != nil {
		a.trayEnd()
	}
}

// beforeClose intercepts the window close button and hides the window instead
// of quitting — keeps the app alive in the system tray.
func (a *App) beforeClose(ctx context.Context) (prevent bool) {
	wruntime.WindowHide(ctx)
	return true
}

// GetQueue returns the current email queue. Returns nil (empty) until Plan 03
// wires the watcher.
func (a *App) GetQueue() []mapi.EmailWithId { return nil }
