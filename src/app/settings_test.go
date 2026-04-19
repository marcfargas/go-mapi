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

	want := AppSettings{Mode: "auto-draft"}
	if err := saveSettings(want); err != nil {
		t.Fatalf("saveSettings: %v", err)
	}
	got := loadSettings()
	if got.Mode != want.Mode {
		t.Errorf("round-trip mismatch: got %+v, want %+v", got, want)
	}
}

// TestLoadDefaultsOnFirstRun: empty dir → defaults.
func TestLoadDefaultsOnFirstRun(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)

	got := loadSettings()
	if got.Mode != "manual" {
		t.Errorf("first-run should default to manual: got %q", got.Mode)
	}
}

// TestLoadDefaultsOnCorruptJSON: garbage file → defaults, no error, no panic.
func TestLoadDefaultsOnCorruptJSON(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)

	// GOMAPI_APPDATA_DIR = dir, so settingsPath() = dir/settings.json
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), []byte("{not valid json"), 0600); err != nil {
		t.Fatal(err)
	}
	got := loadSettings()
	if got.Mode != "manual" {
		t.Errorf("corrupt JSON should default to manual: got %q", got.Mode)
	}
}

// TestLoadNormalizesUnknownMode: unknown Mode value → default.
func TestLoadNormalizesUnknownMode(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)

	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), []byte(`{"mode":"banana-bread"}`), 0600); err != nil {
		t.Fatal(err)
	}
	got := loadSettings()
	if got.Mode != "manual" {
		t.Errorf("unknown mode should normalize to manual: got %q", got.Mode)
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
	got := loadSettings()
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
