package main

import "testing"

func TestLegacyDefaultAppsFlagRoundTripsWithoutChangingOtherPreferences(t *testing.T) {
	t.Setenv("GOMAPI_APPDATA_DIR", t.TempDir())
	want := AppSettings{
		Mode: "auto-draft", AutostartEnabled: false,
		DefaultAppsPrompted: true, UpdateChecksEnabled: false,
		LastUpdateCheck: "2026-09-28T08:00:00Z",
	}
	if err := saveSettings(want); err != nil {
		t.Fatal(err)
	}
	got := loadSettings()
	if got.Issue != nil || got.Settings != want {
		t.Fatalf("legacy flag/preferences changed: got %+v, want %+v", got, want)
	}
}
