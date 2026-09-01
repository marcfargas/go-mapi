package main

import (
	"context"
	"time"

	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

func (a *App) refreshComponentHealth() ComponentHealthState {
	state := newProductionComponentHealthProbe(Version, watcherDir()).probe()
	a.componentHealth.store(state)
	if a.adminInstall != nil {
		a.adminInstall.observe(state)
	}
	if a.ctx != nil {
		wruntime.EventsEmit(a.ctx, "component-health-changed", state)
	}
	return state
}

// GetComponentHealth is the explicit Wails query. It performs a fresh,
// query-only probe so the repair UI never relies solely on a timer snapshot.
func (a *App) GetComponentHealth() ComponentHealthState { return a.refreshComponentHealth() }

// GetAdminInstallState returns the consented repair-flow snapshot. Refreshing
// first keeps it attached to the version-gate health authority rather than a
// second compatibility policy.
func (a *App) GetAdminInstallState() AdminInstallState {
	a.refreshComponentHealth()
	if a.adminInstall == nil {
		return adminInstallStateForHealth(a.componentHealth.load(), time.Now)
	}
	return a.adminInstall.snapshot()
}

// StartAdminRepair records the user's explicit repair action. It accepts no
// caller-controlled artifact, URL, version, registry, or command arguments.
func (a *App) StartAdminRepair() error {
	if a.adminInstall == nil {
		return errAdminReleaseContractUnavailable
	}
	// Once the user approves elevation, Windows Installer owns the launched
	// process. App shutdown must not cancel that process or turn a valid repair
	// into a partial install; pre-elevation cancellation will be an explicit UI
	// operation in the signed-release implementation.
	return a.adminInstall.start(context.Background())
}

func (a *App) startComponentHealthLoop(ctx context.Context) {
	a.refreshComponentHealth()
	go func() {
		ticker := time.NewTicker(componentHealthRefreshInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				a.refreshComponentHealth()
			}
		}
	}()
}
