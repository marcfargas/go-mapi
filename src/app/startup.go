package main

import (
	"context"
	"fmt"
)

const userStartupTaskID = "go-mapi-user-startup-v4"

// StartupState deliberately separates the persisted user request from what
// Windows has registered and will actually run.
type StartupState struct {
	Backend    string `json:"backend"`
	Requested  bool   `json:"requested"`
	Registered bool   `json:"registered"`
	Effective  string `json:"effective"`
	Warning    string `json:"warning,omitempty"`
}

type startupService interface {
	State(context.Context, bool) StartupState
	Set(context.Context, bool) StartupState
	OpenSettings() error
}

func (a *App) GetStartupState() StartupState {
	a.settingsMu.RLock()
	requested := a.settings.AutostartEnabled
	a.settingsMu.RUnlock()
	ctx := a.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	return a.startupService.State(ctx, requested)
}

// SetAutostartEnabled records the user's requested preference even when
// Windows denies the operation. The returned state then exposes the mismatch
// and remediation instead of silently pretending registration succeeded.
func (a *App) SetAutostartEnabled(enabled bool) (StartupState, error) {
	a.settingsMu.RLock()
	s := a.settings
	a.settingsMu.RUnlock()
	s.AutostartEnabled = enabled
	if err := a.SaveSettings(s); err != nil {
		return StartupState{}, fmt.Errorf("save autostart preference: %w", err)
	}
	ctx := a.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	state := a.startupService.Set(ctx, enabled)
	return state, nil
}

func (a *App) OpenStartupSettings() error {
	return a.startupService.OpenSettings()
}

// configureAutostartFromInstaller applies the standalone installer's explicit
// checkbox choice through the same persistence and Windows backend used by the
// UI. This keeps opt-out durable instead of letting first-run defaults silently
// turn startup back on.
func configureAutostartFromInstaller(ctx context.Context, enabled bool) error {
	loaded := loadSettings()
	if loaded.Issue != nil {
		return fmt.Errorf("cannot preserve existing settings: %s", loaded.Issue.Message)
	}
	settings := loaded.Settings
	settings.AutostartEnabled = enabled
	if err := saveSettings(settings); err != nil {
		return fmt.Errorf("save startup preference: %w", err)
	}
	state := newStartupService().Set(ctx, enabled)
	if state.Effective == "error" || state.Effective == "unsafe" || state.Effective == "mismatched" {
		return fmt.Errorf("apply startup preference: %s", state.Warning)
	}
	if enabled && state.Effective != "enabled" {
		return fmt.Errorf("apply startup preference: expected enabled, got %s (%s)", state.Effective, state.Warning)
	}
	return nil
}
