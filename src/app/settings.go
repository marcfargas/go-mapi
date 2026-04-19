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
// only `Mode`. Future phases may add flat fields — do NOT nest. Marshaled to
// %APPDATA%\go-mapi\settings.json via saveSettings (atomic, crash-safe).
//
// Pause state is INTENTIONALLY not persisted (D-15) — resets on every app
// start to prevent "I paused a month ago and forgot" silent failure mode.
type AppSettings struct {
	Mode string `json:"mode"` // "manual" | "auto-draft"
}

const defaultMode = "manual"

// settingsPath returns the full path to settings.json.
// Lives under the per-user appDataDir() (see paths.go) — RDS-safe per-user scope.
func settingsPath() string {
	return filepath.Join(appDataDir(), "settings.json")
}

// loadSettings reads %APPDATA%\go-mapi\settings.json. Returns defaults on
// any read/parse error (first-run missing file, corrupt file, unknown Mode
// value). Corrupt files are NOT moved aside in Phase 9 — D-15 scope means
// the only persisted field is Mode, and resetting to "manual" on a corrupt
// read is the safe default (fail-closed — no auto-draft without a valid
// mode setting).
func loadSettings() AppSettings {
	data, err := os.ReadFile(settingsPath())
	if err != nil {
		// ENOENT or any other read error → defaults. First-run is the
		// common case; no log to avoid noise.
		return AppSettings{Mode: defaultMode}
	}
	var s AppSettings
	if err := json.Unmarshal(data, &s); err != nil {
		logError("settings: parse error, using defaults: %v", err)
		return AppSettings{Mode: defaultMode}
	}
	if s.Mode != "manual" && s.Mode != "auto-draft" {
		// Unknown value from a manual edit or older version — normalize.
		return AppSettings{Mode: defaultMode}
	}
	return s
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
