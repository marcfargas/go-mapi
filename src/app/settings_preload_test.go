package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// These tests observe the App exactly as the frontend can see it before
// startup() runs: Wails dispatches binding calls concurrently with OnStartup,
// so every query and startup write must already reflect the saved settings.
// They deliberately never call startup().

const preloadLastUpdateCheck = "2026-09-01T10:00:00Z"

func writePreloadSettings(t *testing.T, data []byte) {
	t.Helper()
	t.Setenv("GOMAPI_APPDATA_DIR", t.TempDir())
	path := settingsPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir settings dir: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write settings: %v", err)
	}
}

func readPreloadSettingsFile(t *testing.T) map[string]any {
	t.Helper()
	data, err := os.ReadFile(settingsPath())
	if err != nil {
		t.Fatalf("read settings: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatalf("parse settings: %v (%s)", err, data)
	}
	return out
}

func TestSettingsPreload(t *testing.T) {
	t.Run("saved opt-out is visible before startup", func(t *testing.T) {
		writePreloadSettings(t, []byte(`{"mode":"auto-draft","autostart_enabled":false,"update_checks_enabled":false,"last_update_check":"`+preloadLastUpdateCheck+`"}`))
		app := NewApp()
		app.startupService = &recordingStartupService{}

		want := AppSettings{
			Mode:                "auto-draft",
			AutostartEnabled:    false,
			UpdateChecksEnabled: false,
			LastUpdateCheck:     preloadLastUpdateCheck,
		}
		if got := app.GetStartupState(); got.Requested {
			t.Errorf("GetStartupState().Requested = true before startup; saved preference is off")
		}
		state := app.GetSettingsState()
		if state.Issue != nil {
			t.Errorf("GetSettingsState().Issue = %+v, want nil", state.Issue)
		}
		if !reflect.DeepEqual(state.Settings, want) {
			t.Errorf("GetSettingsState().Settings = %+v, want saved %+v", state.Settings, want)
		}
		if got := app.GetSettings(); !reflect.DeepEqual(got, want) {
			t.Errorf("GetSettings() = %+v, want saved %+v", got, want)
		}
		if got := app.GetMode(); got != "auto-draft" {
			t.Errorf("GetMode() = %q, want saved auto-draft", got)
		}
	})

	t.Run("pre-startup write keeps the other saved fields", func(t *testing.T) {
		writePreloadSettings(t, []byte(`{"mode":"auto-draft","autostart_enabled":true,"update_checks_enabled":false,"last_update_check":"`+preloadLastUpdateCheck+`"}`))
		app := NewApp()
		service := &recordingStartupService{}
		app.startupService = service

		if _, err := app.SetAutostartEnabled(false); err != nil {
			t.Fatalf("SetAutostartEnabled(false): %v", err)
		}
		saved := readPreloadSettingsFile(t)
		if saved["autostart_enabled"] != false {
			t.Errorf("saved autostart_enabled = %v, want false", saved["autostart_enabled"])
		}
		if saved["mode"] != "auto-draft" {
			t.Errorf("saved mode = %v, want auto-draft preserved", saved["mode"])
		}
		if saved["update_checks_enabled"] != false {
			t.Errorf("saved update_checks_enabled = %v, want false preserved", saved["update_checks_enabled"])
		}
		if saved["last_update_check"] != preloadLastUpdateCheck {
			t.Errorf("saved last_update_check = %v, want %s preserved", saved["last_update_check"], preloadLastUpdateCheck)
		}
		if !reflect.DeepEqual(service.sets, []bool{false}) {
			t.Errorf("startup service sets = %v, want [false]", service.sets)
		}
	})

	t.Run("malformed file is reported and protected", func(t *testing.T) {
		malformed := []byte(`{"mode":"auto-draft","autostart_enabled":false,`)
		writePreloadSettings(t, malformed)
		app := NewApp()
		service := &recordingStartupService{}
		app.startupService = service

		if state := app.GetSettingsState(); state.Issue == nil {
			t.Errorf("GetSettingsState().Issue = nil before startup; malformed settings must be reported")
		}
		if _, err := app.SetAutostartEnabled(true); err == nil {
			t.Errorf("SetAutostartEnabled(true) succeeded with malformed settings; want an error")
		}
		after, err := os.ReadFile(settingsPath())
		if err != nil {
			t.Fatalf("read settings after write attempt: %v", err)
		}
		if !bytes.Equal(after, malformed) {
			t.Errorf("malformed settings were overwritten: %s", after)
		}
		if len(service.sets) != 0 {
			t.Errorf("startup service sets = %v, want no registration change", service.sets)
		}
	})
}
