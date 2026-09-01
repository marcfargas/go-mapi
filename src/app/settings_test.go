//go:build windows

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestSaveLoadRoundTrip: save → load returns the same AppSettings.
// Subtests cannot t.Parallel — they mutate process-wide env vars.
func TestSaveLoadRoundTrip(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)

	want := AppSettings{Mode: "auto-draft", AutostartEnabled: true}
	if err := saveSettings(want); err != nil {
		t.Fatalf("saveSettings: %v", err)
	}
	result := loadSettings()
	if result.Issue != nil {
		t.Fatalf("loadSettings issue: %+v", result.Issue)
	}
	got := result.Settings
	if got.Mode != want.Mode {
		t.Errorf("round-trip mismatch: got %+v, want %+v", got, want)
	}
}

// TestLoadDefaultsOnFirstRun: empty dir → defaults.
func TestLoadDefaultsOnFirstRun(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)

	result := loadSettings()
	if result.Issue != nil {
		t.Fatalf("first-run issue: %+v", result.Issue)
	}
	got := result.Settings
	if got.Mode != "manual" {
		t.Errorf("first-run should default to manual: got %q", got.Mode)
	}
	if !got.AutostartEnabled {
		t.Error("first-run should enable autostart")
	}
}

// TestLoadReportsCorruptJSON: garbage is preserved and explicitly reported.
func TestLoadReportsCorruptJSON(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)

	// GOMAPI_APPDATA_DIR = dir, so settingsPath() = dir/settings.json
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), []byte("{not valid json"), 0600); err != nil {
		t.Fatal(err)
	}
	result := loadSettings()
	if result.Issue == nil || result.Issue.Kind != "malformed" {
		t.Fatalf("corrupt JSON issue = %+v, want malformed", result.Issue)
	}
	if result.Settings.Mode != "" {
		t.Errorf("corrupt JSON must not claim manual mode: got %q", result.Settings.Mode)
	}
}

// TestLoadReportsUnknownMode: unknown values are never silently normalized.
func TestLoadReportsUnknownMode(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)

	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), []byte(`{"mode":"banana-bread"}`), 0600); err != nil {
		t.Fatal(err)
	}
	result := loadSettings()
	if result.Issue == nil || result.Issue.Kind != "invalid-mode" {
		t.Fatalf("unknown mode issue = %+v, want invalid-mode", result.Issue)
	}
	if result.Settings.Mode != "" {
		t.Errorf("unknown mode must not normalize to manual: got %q", result.Settings.Mode)
	}
}

func TestLoadAcceptsAdditiveFieldsAndDefaultsAutostart(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)
	data := []byte(`{"mode":"auto-draft","future_field":{"enabled":true}}`)
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	result := loadSettings()
	if result.Issue != nil {
		t.Fatalf("additive field issue: %+v", result.Issue)
	}
	if result.Settings.Mode != "auto-draft" || !result.Settings.AutostartEnabled {
		t.Fatalf("loaded settings = %+v", result.Settings)
	}
}

func TestLoadReportsUnreadableSettingsPath(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)
	if err := os.Mkdir(filepath.Join(dir, "settings.json"), 0700); err != nil {
		t.Fatal(err)
	}
	result := loadSettings()
	if result.Issue == nil || result.Issue.Kind != "read" {
		t.Fatalf("unreadable settings issue = %+v, want read", result.Issue)
	}
	if result.Settings.Mode != "" {
		t.Fatalf("unreadable settings must inhibit mode, got %q", result.Settings.Mode)
	}
}

// TestSaveOverwritesAtomically: two saveSettings calls; second value wins;
// no tmp files leak after.
func TestSaveOverwritesAtomically(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)

	if err := saveSettings(AppSettings{Mode: "manual"}); err != nil {
		t.Fatal(err)
	}
	if err := saveSettings(AppSettings{Mode: "auto-draft"}); err != nil {
		t.Fatal(err)
	}
	got := loadSettings().Settings
	if got.Mode != "auto-draft" {
		t.Errorf("second save should win: got %q", got.Mode)
	}
	// No stale tmp files.
	matches, err := filepath.Glob(filepath.Join(dir, "settings-*.tmp"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) > 0 {
		t.Errorf("leftover tmp files: %v", matches)
	}
}

// TestSaveCreatesMissingDir: fresh TempDir subdir that does not exist → save creates it.
func TestSaveCreatesMissingDir(t *testing.T) {
	base := t.TempDir()
	nested := filepath.Join(base, "never-created-yet")
	t.Setenv("GOMAPI_APPDATA_DIR", nested)

	if err := saveSettings(AppSettings{Mode: "auto-draft"}); err != nil {
		t.Fatalf("saveSettings with missing dir: %v", err)
	}
	if _, err := os.Stat(filepath.Join(nested, "settings.json")); err != nil {
		t.Errorf("settings.json not created under %s: %v", nested, err)
	}
}
