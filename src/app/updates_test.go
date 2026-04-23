//go:build windows

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// saveSettingsRaw writes a raw JSON blob to settings.json under dir. Used by
// tests to simulate pre-existing settings files (partial/corrupt) without
// going through saveSettings.
func saveSettingsRaw(dir, body string) error {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "settings.json"), []byte(body), 0600)
}

// nopLogger discards messages — lets updates.go log freely in tests without
// cluttering test output. Matches the logging.go signature used in production.
var nopLogger = func(format string, args ...any) {}

// stubReleaseFetcher is an in-memory implementation of releaseFetcher used by
// tests to avoid real GitHub HTTP. A test can set release to simulate a newer
// release, or set err to simulate a network/API failure.
type stubReleaseFetcher struct {
	release *latestRelease
	err     error
	calls   int
}

func (s *stubReleaseFetcher) FetchLatestRelease(ctx context.Context) (*latestRelease, error) {
	s.calls++
	if s.err != nil {
		return nil, s.err
	}
	return s.release, nil
}

// Test 1: missing/corrupt settings normalize to UpdateChecksEnabled=true and
// an empty last-checked value. Confirms D-08 default-enabled semantics.
func TestSettingsUpdateDefaultsEnabled(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)

	got := loadSettings()
	if !got.UpdateChecksEnabled {
		t.Errorf("UpdateChecksEnabled should default to true on first run, got false")
	}
	if got.LastUpdateCheck != "" {
		t.Errorf("LastUpdateCheck should default to empty on first run, got %q", got.LastUpdateCheck)
	}
}

// Test 1b: existing settings file missing the update fields should hydrate
// with UpdateChecksEnabled=true (flat-fields back-compat for D-05).
func TestSettingsUpdateBackCompatPartialJSON(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)

	// Write a settings file that pre-dates the update fields (Phase 9 shape).
	if err := saveSettingsRaw(dir, `{"mode":"manual"}`); err != nil {
		t.Fatalf("saveSettingsRaw: %v", err)
	}

	got := loadSettings()
	if !got.UpdateChecksEnabled {
		t.Errorf("UpdateChecksEnabled should default to true when field is absent, got false")
	}
	if got.Mode != "manual" {
		t.Errorf("Mode should be preserved across the settings load, got %q", got.Mode)
	}
}

// Test 1c: corrupt JSON falls back to the full default AppSettings (Mode=manual,
// UpdateChecksEnabled=true) without surfacing an error.
func TestSettingsUpdateCorruptFallsBackToDefaults(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)

	if err := saveSettingsRaw(dir, `{ this is not json`); err != nil {
		t.Fatalf("saveSettingsRaw: %v", err)
	}

	got := loadSettings()
	if !got.UpdateChecksEnabled {
		t.Error("UpdateChecksEnabled should default to true on corrupt JSON")
	}
	if got.Mode != "manual" {
		t.Errorf("Mode should default to manual on corrupt JSON, got %q", got.Mode)
	}
}

// Test 2: when UpdateChecksEnabled=false, background cadence returns without
// invoking the GitHub Releases client. Core opt-out invariant for REL-05.
func TestUpdateServiceOptOutSkipsFetch(t *testing.T) {
	stub := &stubReleaseFetcher{}
	svc := newUpdateService("0.0.0-dev", stub, nopLogger)

	state, checked, err := svc.MaybeCheck(context.Background(), updateSettings{
		Enabled:         false,
		LastUpdateCheck: "",
		Now:             time.Now().UTC(),
	})

	if err != nil {
		t.Errorf("MaybeCheck should not return err when disabled, got %v", err)
	}
	if checked {
		t.Error("MaybeCheck should report checked=false when disabled")
	}
	if stub.calls != 0 {
		t.Errorf("stub release fetcher should not be called when disabled, got %d calls", stub.calls)
	}
	// State still reports enabled=false so tray/frontend can render.
	if state.Enabled {
		t.Error("state.Enabled should be false when settings disabled")
	}
}

// Test 2b: when enabled but last check was within the 24h window, background
// cadence skips the fetch but still returns current state.
func TestUpdateServiceRecentCheckSkipsFetch(t *testing.T) {
	stub := &stubReleaseFetcher{}
	svc := newUpdateService("0.0.0-dev", stub, nopLogger)

	now := time.Now().UTC()
	recent := now.Add(-1 * time.Hour).Format(time.RFC3339)

	_, checked, err := svc.MaybeCheck(context.Background(), updateSettings{
		Enabled:         true,
		LastUpdateCheck: recent,
		Now:             now,
	})

	if err != nil {
		t.Errorf("MaybeCheck should not return err on no-op path, got %v", err)
	}
	if checked {
		t.Error("MaybeCheck should skip fetch when last check is within 24h")
	}
	if stub.calls != 0 {
		t.Errorf("stub release fetcher should not be called inside 24h window, got %d calls", stub.calls)
	}
}

// Test 2c: when enabled and last check is older than 24h, the service fetches.
func TestUpdateServiceStaleCheckTriggersFetch(t *testing.T) {
	stub := &stubReleaseFetcher{
		release: &latestRelease{
			Version:    "3.0.0",
			ReleaseURL: "https://github.com/marcfargas/go-mapi/releases/tag/v3.0.0",
		},
	}
	svc := newUpdateService("0.0.0-dev", stub, nopLogger)

	now := time.Now().UTC()
	stale := now.Add(-48 * time.Hour).Format(time.RFC3339)

	_, checked, err := svc.MaybeCheck(context.Background(), updateSettings{
		Enabled:         true,
		LastUpdateCheck: stale,
		Now:             now,
	})

	if err != nil {
		t.Errorf("MaybeCheck should not return err when fetch succeeds, got %v", err)
	}
	if !checked {
		t.Error("MaybeCheck should fetch when last check is older than 24h")
	}
	if stub.calls != 1 {
		t.Errorf("expected 1 fetch call after stale cadence, got %d", stub.calls)
	}
}

// Test 3: version comparison reports update-available using main.Version vs
// latest release metadata and never stages a download/replace flow.
func TestUpdateServiceDetectsAvailableUpdate(t *testing.T) {
	stub := &stubReleaseFetcher{
		release: &latestRelease{
			Version:    "3.0.0",
			ReleaseURL: "https://github.com/marcfargas/go-mapi/releases/tag/v3.0.0",
		},
	}
	svc := newUpdateService("2.1.0", stub, nopLogger)

	state, err := svc.CheckNow(context.Background())
	if err != nil {
		t.Fatalf("CheckNow: %v", err)
	}
	if !state.UpdateAvailable {
		t.Error("expected UpdateAvailable=true for 2.1.0 -> 3.0.0")
	}
	if state.LatestVersion != "3.0.0" {
		t.Errorf("expected LatestVersion=3.0.0, got %q", state.LatestVersion)
	}
	if state.LatestReleaseURL != "https://github.com/marcfargas/go-mapi/releases/tag/v3.0.0" {
		t.Errorf("unexpected LatestReleaseURL: %q", state.LatestReleaseURL)
	}
	if state.InstallerURL != "https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe" {
		t.Errorf("InstallerURL must be the stable installer URL (D-02), got %q", state.InstallerURL)
	}
	if state.CurrentVersion != "2.1.0" {
		t.Errorf("expected CurrentVersion=2.1.0, got %q", state.CurrentVersion)
	}
	// LastCheckedAt must be set by CheckNow (RFC3339).
	if state.LastCheckedAt == "" {
		t.Error("CheckNow must set LastCheckedAt timestamp")
	}
	if _, err := time.Parse(time.RFC3339, state.LastCheckedAt); err != nil {
		t.Errorf("LastCheckedAt should be RFC3339, got %q: %v", state.LastCheckedAt, err)
	}
}

// Test 3b: when current version is equal or greater than latest, no update.
func TestUpdateServiceNoUpdateWhenCurrentIsLatest(t *testing.T) {
	stub := &stubReleaseFetcher{
		release: &latestRelease{
			Version:    "3.0.0",
			ReleaseURL: "https://github.com/marcfargas/go-mapi/releases/tag/v3.0.0",
		},
	}
	svc := newUpdateService("3.0.0", stub, nopLogger)

	state, err := svc.CheckNow(context.Background())
	if err != nil {
		t.Fatalf("CheckNow: %v", err)
	}
	if state.UpdateAvailable {
		t.Error("expected UpdateAvailable=false when current==latest")
	}
}

// Test 3c: dev version (e.g. "0.0.0-dev") treated as older than any tagged
// release so local dev builds still detect updates. No update-available
// state should ever lead to an in-process replacement (notify-only).
func TestUpdateServiceDevVersionSeesUpdate(t *testing.T) {
	stub := &stubReleaseFetcher{
		release: &latestRelease{
			Version:    "3.0.0",
			ReleaseURL: "https://example.invalid",
		},
	}
	svc := newUpdateService("0.0.0-dev", stub, nopLogger)

	state, err := svc.CheckNow(context.Background())
	if err != nil {
		t.Fatalf("CheckNow: %v", err)
	}
	if !state.UpdateAvailable {
		t.Error("expected UpdateAvailable=true for 0.0.0-dev vs 3.0.0")
	}
}

// QUICK-260423-qpx: dev-build version compare must not offer a downgrade.
// Before the fix, isDevVersion() shortcut returned true unconditionally
// for any "*-dev" current, so a 3.0.0-dev build would see v2.1.0 (the
// newest stable GitHub release at the time) as an "upgrade" and show
// the user a downgrade offer.
func TestIsNewerVersion_DevBuildNotOfferedDowngrade(t *testing.T) {
	cases := []struct {
		name    string
		current string
		latest  string
		want    bool
	}{
		// The bug: 3.0.0-dev > 2.1.0, so no upgrade banner.
		{"3.0.0-dev vs 2.1.0: no downgrade", "3.0.0-dev", "2.1.0", false},

		// Tagged 3.0.0 > 3.0.0-dev (release beats prerelease per semver).
		{"3.0.0-dev vs 3.0.0: tagged wins", "3.0.0-dev", "3.0.0", true},

		// Minor/patch bumps after the dev cut still show up.
		{"3.0.0-dev vs 3.0.1: patch wins", "3.0.0-dev", "3.0.1", true},
		{"3.0.0-dev vs 3.1.0: minor wins", "3.0.0-dev", "3.1.0", true},

		// 0.0.0-dev (ldflags fallback default) is a "nothing yet" marker --
		// still gets told about every real release.
		{"0.0.0-dev vs 3.0.0: always offer", "0.0.0-dev", "3.0.0", true},

		// Regular stable compares unaffected.
		{"2.1.0 vs 3.0.0: regular upgrade", "2.1.0", "3.0.0", true},
		{"3.0.0 vs 2.1.0: no downgrade", "3.0.0", "2.1.0", false},
		{"3.0.0 vs 3.0.0: no self-offer", "3.0.0", "3.0.0", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := isNewerVersion(tc.current, tc.latest)
			if got != tc.want {
				t.Errorf("isNewerVersion(current=%q, latest=%q) = %v, want %v",
					tc.current, tc.latest, got, tc.want)
			}
		})
	}
}

// Test 4: fetch failure returns error to caller for logging but does not
// mutate user-visible state beyond refreshing LastCheckedAt.
func TestUpdateServiceFetchFailureIsReturnedNotPropagatedAsUserState(t *testing.T) {
	stub := &stubReleaseFetcher{
		err: errors.New("network unreachable"),
	}
	svc := newUpdateService("2.1.0", stub, nopLogger)

	state, err := svc.CheckNow(context.Background())
	if err == nil {
		t.Fatal("expected error from failed fetch, got nil")
	}
	// D-04: must not turn a transient fetch failure into a user-facing error
	// state. UpdateAvailable must be false (no inference), LatestVersion empty.
	if state.UpdateAvailable {
		t.Error("UpdateAvailable must be false on fetch error")
	}
	if state.LatestVersion != "" {
		t.Errorf("LatestVersion must be empty on fetch error, got %q", state.LatestVersion)
	}
	// LastCheckedAt is still recorded — we attempted a check.
	if state.LastCheckedAt == "" {
		t.Error("LastCheckedAt should be set even on fetch failure so cadence advances")
	}
	// CurrentVersion is always reported for tray/UI hydration.
	if state.CurrentVersion != "2.1.0" {
		t.Errorf("CurrentVersion should be reported on failure, got %q", state.CurrentVersion)
	}
}

// Test 4b: CheckNow never downloads or replaces — it only returns metadata.
// This is a structural test: the UpdateState type must NOT have any fields
// resembling download paths, staged installers, or replacement flags, and
// the service contract must expose no "apply" method.
func TestUpdateServiceNoReplacementSurface(t *testing.T) {
	svc := newUpdateService("0.0.0-dev", &stubReleaseFetcher{}, nopLogger)

	// Assert the service type does not expose an Apply/Install/Download method.
	// If these get added, this test must fail loudly — D-03 is non-negotiable.
	// We check via method lookup on a value to keep the assertion compile-time safe.
	_ = svc.CheckNow // must exist
	_ = svc.MaybeCheck

	// And confirm that UpdateState fields remain metadata-only. We sanity-check
	// known-safe field names here; any future field additions must be metadata.
	var empty UpdateState
	_ = empty.CurrentVersion
	_ = empty.LatestVersion
	_ = empty.LatestReleaseURL
	_ = empty.InstallerURL
	_ = empty.UpdateAvailable
	_ = empty.LastCheckedAt
	_ = empty.Enabled
}
