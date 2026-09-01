//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// AppSettings is the persisted per-user settings for go-mapi. Phase 9 ships
// `Mode`; Phase 11 adds the flat update-check fields. Future phases may add
// flat fields — do NOT nest. Marshaled to %APPDATA%\go-mapi\settings.json
// via saveSettings (atomic, crash-safe).
//
// Pause state is INTENTIONALLY not persisted (D-15) — resets on every app
// start to prevent "I paused a month ago and forgot" silent failure mode.
//
// Update-check fields (Phase 11, D-05/D-07/D-08):
//   - UpdateChecksEnabled: user opt-out toggle (REL-05). Defaults to true so
//     existing settings files missing the field still get update checks.
//   - LastUpdateCheck: RFC3339 timestamp of the most recent check attempt
//     (success OR failure). Empty string on first run / never-checked.
//     Consumed by the cadence gate and by tray/frontend "Last checked" status
//     (D-07). Background goroutines MUST NOT call saveSettings directly —
//     persistence is routed through an App-owned guarded writer (Task 2)
//     that preserves the single-writer atomic-save invariant.
type AppSettings struct {
	Mode                string `json:"mode"`                        // "manual" | "auto-draft"
	AutostartEnabled    bool   `json:"autostart_enabled"`           // user preference; default enabled
	DefaultAppsPrompted bool   `json:"default_apps_prompted"`       // avoids repeatedly prompting after dismissal
	UpdateChecksEnabled bool   `json:"update_checks_enabled"`       // D-08 default enabled
	LastUpdateCheck     string `json:"last_update_check,omitempty"` // RFC3339, "" = never checked
}

// SettingsIssue is returned when an existing settings file cannot be used.
// The original file is never replaced automatically: the UI must ask the user
// to repair it by explicitly saving a supported configuration.
type SettingsIssue struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
	Path    string `json:"path"`
}

// SettingsLoadResult keeps invalid configuration distinct from valid defaults.
// In particular, Settings.Mode is empty when Issue is non-nil, so callers can
// never accidentally report an invalid value as effective manual mode.
type SettingsLoadResult struct {
	Settings AppSettings    `json:"settings"`
	Issue    *SettingsIssue `json:"issue,omitempty"`
}

const defaultMode = "manual"

// defaultAppSettings returns the settings used on first run, corrupt file,
// or any other fallback path. Keeping this one builder means every fallback
// code path gets the same defaults — notably D-08 UpdateChecksEnabled=true.
func defaultAppSettings() AppSettings {
	return AppSettings{
		Mode:                defaultMode,
		AutostartEnabled:    true,
		UpdateChecksEnabled: true,
	}
}

// settingsPath returns the full path to settings.json.
// Lives under the per-user appDataDir() (see paths.go) — RDS-safe per-user scope.
func settingsPath() string {
	return filepath.Join(appDataDir(), "settings.json")
}

// loadSettings reads %APPDATA%\go-mapi\settings.json. A missing file is a
// normal first-run state. Every other read/parse/validation failure is
// explicit and leaves Mode empty, which fail-closes automode without falsely
// claiming that manual mode was selected.
func loadSettings() SettingsLoadResult {
	path := settingsPath()
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return SettingsLoadResult{Settings: defaultAppSettings()}
		}
		return invalidSettingsResult("read", path, fmt.Sprintf("Cannot read settings: %v", err))
	}
	// Intermediate shape with a *bool for the update toggle so we can tell
	// "field absent from JSON" (partial/old file) from "field explicitly
	// set to false" (user opted out). Absent → default true per D-08.
	var raw struct {
		Mode                string `json:"mode"`
		AutostartEnabled    *bool  `json:"autostart_enabled"`
		DefaultAppsPrompted bool   `json:"default_apps_prompted"`
		UpdateChecksEnabled *bool  `json:"update_checks_enabled"`
		LastUpdateCheck     string `json:"last_update_check"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return invalidSettingsResult("malformed", path, fmt.Sprintf("Settings JSON is malformed: %v", err))
	}
	if raw.Mode != "manual" && raw.Mode != "auto-draft" {
		return invalidSettingsResult("invalid-mode", path, fmt.Sprintf("Unsupported mode %q; choose manual or auto-draft", raw.Mode))
	}
	out := defaultAppSettings()
	out.Mode = raw.Mode
	if raw.AutostartEnabled != nil {
		out.AutostartEnabled = *raw.AutostartEnabled
	}
	out.DefaultAppsPrompted = raw.DefaultAppsPrompted
	if raw.UpdateChecksEnabled != nil {
		out.UpdateChecksEnabled = *raw.UpdateChecksEnabled
	}
	out.LastUpdateCheck = raw.LastUpdateCheck
	return SettingsLoadResult{Settings: out}
}

func invalidSettingsResult(kind, path, message string) SettingsLoadResult {
	defaults := defaultAppSettings()
	defaults.Mode = ""
	return SettingsLoadResult{
		Settings: defaults,
		Issue: &SettingsIssue{
			Kind:    kind,
			Message: message,
			Path:    path,
		},
	}
}

// saveSettings writes s atomically. Pattern (RESEARCH §3):
//  1. Marshal to JSON.
//  2. MkdirAll the target dir.
//  3. Create tmp file in SAME directory (same-volume required for atomic rename).
//  4. Write + Sync + Close the tmp file.
//  5. windows.MoveFileEx(tmp, dest, REPLACE_EXISTING|WRITE_THROUGH) — atomic on NTFS.
//  6. On any error, best-effort unlink tmp.
//
// SINGLE-WRITER INVARIANT: only call from Wails bindings (UI thread). Never
// from a goroutine (automode, watcher, auth refresh). D-13 + RESEARCH §3.
func saveSettings(s AppSettings) error {
	path := settingsPath()
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return fmt.Errorf("settings: mkdir: %w", err)
	}
	data, err := json.Marshal(s)
	if err != nil {
		return fmt.Errorf("settings: marshal: %w", err)
	}
	tmp, err := os.CreateTemp(dir, "settings-*.tmp")
	if err != nil {
		return fmt.Errorf("settings: create tmp: %w", err)
	}
	tmpPath := tmp.Name()
	defer func() {
		// Best-effort cleanup on any error path. If rename succeeded, tmp
		// is already gone and this Remove is a no-op (ENOENT).
		_ = os.Remove(tmpPath)
	}()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("settings: write tmp: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("settings: sync tmp: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("settings: close tmp: %w", err)
	}
	if err := moveFileAtomic(tmpPath, path); err != nil {
		return fmt.Errorf("settings: atomic rename: %w", err)
	}
	return nil
}

// moveFileAtomic wraps windows.MoveFileEx with REPLACE_EXISTING + WRITE_THROUGH.
// On Windows, os.Rename is NOT atomic when the target exists (issue #8914).
// MoveFileEx IS atomic on NTFS for same-volume source/dest. WRITE_THROUGH
// forces a physical disk commit before return (crash-safe at the cost of
// ~1-5ms latency per save — acceptable for UI-triggered writes).
func moveFileAtomic(src, dst string) error {
	srcW, err := windows.UTF16PtrFromString(src)
	if err != nil {
		return err
	}
	dstW, err := windows.UTF16PtrFromString(dst)
	if err != nil {
		return err
	}
	return windows.MoveFileEx(
		srcW,
		dstW,
		windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH,
	)
}
