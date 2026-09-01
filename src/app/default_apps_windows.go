//go:build windows

package main

import "github.com/pkg/browser"

// OpenDefaultAppsSettings opens the Windows-owned Default Apps UI. go-mapi
// deliberately does not write UserChoice or claim to complete this operation.
func (a *App) OpenDefaultAppsSettings() error {
	return browser.OpenURL("ms-settings:defaultapps")
}

// DismissDefaultAppsPrompt records that the user has handled the guidance so
// it is not shown aggressively on every launch. Windows remains authoritative
// for the actual mail-app choice.
func (a *App) DismissDefaultAppsPrompt() error {
	a.settingsMu.RLock()
	s := a.settings
	a.settingsMu.RUnlock()
	s.DefaultAppsPrompted = true
	return a.SaveSettings(s)
}
