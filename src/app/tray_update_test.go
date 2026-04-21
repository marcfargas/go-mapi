//go:build windows

package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// ---------------------------------------------------------------------
// Phase 11 Plan 02 — Task 1 tests: tray update menu + status rows.
//
// Invariants under test:
//   - D-05: tray menu owns the "Check for updates" toggle; writes MUST go
//     through the App settings path (no second persistence path).
//   - D-06: a manual "Check for updates now" action invokes
//     App.CheckForUpdatesNow().
//   - D-07: version + last-checked text is user-visible via pure helpers
//     that can be formatted from an UpdateState without a live tray host.
//   - D-04: disabled checks (or never-checked state) do NOT render a
//     user-visible error string.
//   - Thread affinity: background callers mutate App state and signal
//     tray refresh — they NEVER touch systray.* directly.
// ---------------------------------------------------------------------

// Test 1a: current-version label formats without error across the
// expected shapes (tagged, dev, empty fallback).
func TestTrayUpdateStatusCurrentVersionLabel(t *testing.T) {
	cases := []struct {
		name string
		in   UpdateState
		want string
	}{
		{"tagged release", UpdateState{CurrentVersion: "v3.0.0"}, "Version v3.0.0"},
		{"dev build", UpdateState{CurrentVersion: "0.0.0-dev"}, "Version 0.0.0-dev"},
		{"empty falls back to unknown", UpdateState{}, "Version unknown"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := formatUpdateCurrentVersionLabel(tc.in)
			if got != tc.want {
				t.Errorf("formatUpdateCurrentVersionLabel: got %q, want %q", got, tc.want)
			}
		})
	}
}

// Test 1b: last-checked label handles never-checked, just-checked,
// relative-time rendering, and ignores malformed input (no error text).
func TestTrayUpdateStatusLastCheckedLabel(t *testing.T) {
	now := time.Date(2026, 4, 21, 12, 0, 0, 0, time.UTC)

	cases := []struct {
		name  string
		state UpdateState
		want  string
	}{
		{
			name:  "never checked (empty)",
			state: UpdateState{LastCheckedAt: ""},
			want:  "Last checked: never",
		},
		{
			name:  "never checked (unparsable)",
			state: UpdateState{LastCheckedAt: "garbage"},
			want:  "Last checked: never",
		},
		{
			name: "just now (< 1 min)",
			state: UpdateState{
				LastCheckedAt: now.Add(-30 * time.Second).Format(time.RFC3339),
			},
			want: "Last checked: just now",
		},
		{
			name: "minutes ago",
			state: UpdateState{
				LastCheckedAt: now.Add(-15 * time.Minute).Format(time.RFC3339),
			},
			want: "Last checked: 15m ago",
		},
		{
			name: "hours ago",
			state: UpdateState{
				LastCheckedAt: now.Add(-3 * time.Hour).Format(time.RFC3339),
			},
			want: "Last checked: 3h ago",
		},
		{
			name: "days ago",
			state: UpdateState{
				LastCheckedAt: now.Add(-48 * time.Hour).Format(time.RFC3339),
			},
			want: "Last checked: 2d ago",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := formatUpdateLastCheckedLabel(tc.state, now)
			if got != tc.want {
				t.Errorf("formatUpdateLastCheckedLabel: got %q, want %q", got, tc.want)
			}
		})
	}
}

// Test 1c: D-04 — a disabled or never-checked state must NOT produce an
// error-looking label. Nothing in the status text should read like a
// user-facing failure.
func TestTrayUpdateStatusNeverShowsErrorForDisabledOrEmpty(t *testing.T) {
	states := []UpdateState{
		{Enabled: false, CurrentVersion: "v3.0.0"},
		{Enabled: true, CurrentVersion: "v3.0.0", LastCheckedAt: ""},
		{Enabled: false, CurrentVersion: "v3.0.0", LastCheckedAt: ""},
	}
	now := time.Now().UTC()
	for _, s := range states {
		ver := strings.ToLower(formatUpdateCurrentVersionLabel(s))
		last := strings.ToLower(formatUpdateLastCheckedLabel(s, now))
		for _, needle := range []string{"error", "failed", "unavailable"} {
			if strings.Contains(ver, needle) {
				t.Errorf("version label %q must not contain %q (D-04)", ver, needle)
			}
			if strings.Contains(last, needle) {
				t.Errorf("last-checked label %q must not contain %q (D-04)", last, needle)
			}
		}
	}
}

// Test 2: update-available flag changes computeTrayVisual's tooltip
// output and clears correctly when flipped back to false. The change
// must be visible in the tooltip so the refresh gate has an observable
// signal, even when no new icon variant is available.
func TestTrayVisualUpdateAvailableAndCleared(t *testing.T) {
	base := trayState{Mode: "manual", SignedIn: true, Count: 0}

	// Baseline — no update: tooltip does NOT mention update.
	_, tipIdle := computeTrayVisual(base)
	if strings.Contains(tipIdle, "Update available") {
		t.Fatalf("baseline tooltip must not mention update: %q", tipIdle)
	}

	// Flip update-available true → tooltip gains the marker.
	withUpdate := base
	withUpdate.UpdateAvailable = true
	iconUp, tipUp := computeTrayVisual(withUpdate)
	if !strings.Contains(tipUp, "Update available") {
		t.Errorf("update-available tooltip must surface the marker: %q", tipUp)
	}

	// Icon must reflect a changed visual state somehow — either a new
	// icon variant or has-queue/update overlap. Assert the icon is NOT
	// the plain idle icon when the only change is UpdateAvailable, so
	// the visual transition is concrete.
	if bytes.Equal(iconUp, trayIdleIcon) {
		t.Errorf("update-available icon must differ from plain idle")
	}

	// Clear the flag → visual snaps back to plain idle, tooltip drops
	// the marker.
	cleared := withUpdate
	cleared.UpdateAvailable = false
	iconClr, tipClr := computeTrayVisual(cleared)
	if strings.Contains(tipClr, "Update available") {
		t.Errorf("cleared tooltip must not mention update: %q", tipClr)
	}
	if !bytes.Equal(iconClr, trayIdleIcon) {
		t.Errorf("cleared state must return to idle icon")
	}

	// Error still wins (D-16 priority 1).
	errState := withUpdate
	errState.ErrorMsg = "watcher stopped"
	iconErr, tipErr := computeTrayVisual(errState)
	if !bytes.Equal(iconErr, trayErrorIcon) {
		t.Errorf("error icon must win over update-available")
	}
	if strings.Contains(tipErr, "Update available") {
		t.Errorf("error tooltip must not also carry update marker: %q", tipErr)
	}
}

// Test 3: toggling "Check for updates" goes through the App settings
// path — the toggle writes via saveSettings atomically. It must NOT
// create a parallel persistence path.
func TestTrayToggleUpdateChecksWritesThroughAppSettings(t *testing.T) {
	tempSettingsEnv(t)
	app := NewApp()
	app.settings = AppSettings{Mode: "manual", UpdateChecksEnabled: true}
	app.updateState.Store(&UpdateState{
		CurrentVersion: "v3.0.0",
		Enabled:        true,
		InstallerURL:   installerDownloadURL,
	})

	// Flip off.
	if err := app.setUpdateChecksEnabled(false); err != nil {
		t.Fatalf("setUpdateChecksEnabled(false): %v", err)
	}

	// Persisted settings reflect the change.
	persisted := loadSettings()
	if persisted.UpdateChecksEnabled {
		t.Errorf("persisted UpdateChecksEnabled should be false after toggle off")
	}
	// In-memory settings reflect the change.
	if app.isUpdateChecksEnabled() {
		t.Errorf("in-memory UpdateChecksEnabled must be false")
	}
	// Cached update state carries the flag through for tray refresh.
	if app.GetUpdateState().Enabled {
		t.Errorf("cached update state Enabled must be false after toggle off")
	}

	// Flip back on.
	if err := app.setUpdateChecksEnabled(true); err != nil {
		t.Fatalf("setUpdateChecksEnabled(true): %v", err)
	}
	persisted = loadSettings()
	if !persisted.UpdateChecksEnabled {
		t.Errorf("persisted UpdateChecksEnabled should be true after toggle on")
	}
	if !app.isUpdateChecksEnabled() {
		t.Errorf("in-memory UpdateChecksEnabled must be true")
	}
	if !app.GetUpdateState().Enabled {
		t.Errorf("cached update state Enabled must be true after toggle on")
	}
}

// Test 3b: the toggle ALSO signals a tray refresh so the menu/tooltip
// picks up the change without blocking on a systray.* call.
func TestTrayToggleUpdateChecksSignalsRefresh(t *testing.T) {
	tempSettingsEnv(t)
	app := NewApp()
	app.settings = AppSettings{Mode: "manual", UpdateChecksEnabled: true}
	app.updateState.Store(&UpdateState{
		CurrentVersion: "v3.0.0",
		Enabled:        true,
	})

	// Drain any pre-existing signal.
	select {
	case <-app.trayRefreshCh:
	default:
	}

	if err := app.setUpdateChecksEnabled(false); err != nil {
		t.Fatalf("setUpdateChecksEnabled: %v", err)
	}

	select {
	case <-app.trayRefreshCh:
		// ok — refresh was signalled.
	case <-time.After(100 * time.Millisecond):
		t.Error("setUpdateChecksEnabled must signal tray refresh so the menu updates")
	}
}

// Test 4: manual "Check for updates now" invokes App.CheckForUpdatesNow
// which runs through the service layer — no systray.* call leaks into
// the caller's goroutine.
func TestTrayManualCheckInvokesAppBinding(t *testing.T) {
	tempSettingsEnv(t)
	fetcher := &countingFetcher{
		release: &latestRelease{
			Version:    "3.0.1",
			ReleaseURL: "https://example.invalid/v3.0.1",
		},
	}
	app := newAppForUpdateTests(t, fetcher, "3.0.0")
	app.settings = AppSettings{UpdateChecksEnabled: true}

	if err := app.CheckForUpdatesNow(context.Background()); err != nil {
		t.Fatalf("CheckForUpdatesNow: %v", err)
	}

	if fetcher.callCount() != 1 {
		t.Errorf("manual check must call fetcher exactly once, got %d", fetcher.callCount())
	}

	state := app.GetUpdateState()
	if !state.UpdateAvailable {
		t.Error("after manual check, UpdateAvailable should be true for a newer release")
	}
	if state.LatestVersion != "3.0.1" {
		t.Errorf("LatestVersion=%q, want %q", state.LatestVersion, "3.0.1")
	}
}

// Test 4b: tray manual-check wiring runs through signalTrayRefresh
// AFTER CheckForUpdatesNow completes, so any non-tray goroutine that
// triggers a manual check ends up with the tray on the refresh path
// rather than calling systray.* directly.
func TestTrayManualCheckSignalsTrayRefresh(t *testing.T) {
	tempSettingsEnv(t)
	fetcher := &countingFetcher{
		release: &latestRelease{Version: "3.0.1"},
	}
	app := newAppForUpdateTests(t, fetcher, "3.0.0")
	app.settings = AppSettings{UpdateChecksEnabled: true}

	// Drain any pre-existing signal.
	select {
	case <-app.trayRefreshCh:
	default:
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		app.runTrayManualUpdateCheck(context.Background())
	}()

	select {
	case <-app.trayRefreshCh:
		// ok
	case <-time.After(500 * time.Millisecond):
		t.Error("manual tray check must signal tray refresh")
	}
	<-done
}

// Test 4c: manual check failure is preserved silently — the caller
// logs, but no user-visible error is surfaced via getLastError
// (D-04). We assert lastErrorMsg stays empty after a failing manual
// check.
func TestTrayManualCheckFailureStaysSilent(t *testing.T) {
	tempSettingsEnv(t)
	fetcher := &countingFetcher{err: errors.New("network timeout")}
	app := newAppForUpdateTests(t, fetcher, "3.0.0")
	app.settings = AppSettings{UpdateChecksEnabled: true}

	// Seed a prior state so we can assert it is preserved.
	app.updateState.Store(&UpdateState{
		CurrentVersion:   "3.0.0",
		LatestVersion:    "3.0.1",
		UpdateAvailable:  true,
		LatestReleaseURL: "https://example.invalid/v3.0.1",
		InstallerURL:     installerDownloadURL,
	})

	_ = app.runTrayManualUpdateCheck(context.Background())

	// D-04: no user-facing error.
	if got := app.getLastError(); got != "" {
		t.Errorf("getLastError after failing manual check = %q, want \"\" (D-04)", got)
	}
	// Prior user-visible state preserved.
	state := app.GetUpdateState()
	if state.LatestVersion != "3.0.1" || !state.UpdateAvailable {
		t.Errorf("failing manual check must preserve prior state, got %+v", state)
	}
}

// Test 5: the refreshTrayVisual path reads UpdateAvailable from the
// cached state. Exercise the state snapshot helper so we are sure the
// tray goroutine reads UpdateAvailable without allocating per-tick.
func TestTraySnapshotCarriesUpdateAvailable(t *testing.T) {
	app := NewApp()
	app.trayRefreshCh = make(chan struct{}, 1)

	// No state yet — snapshot must default to false.
	if got := app.snapshotUpdateAvailable(); got {
		t.Errorf("snapshotUpdateAvailable with no state = true, want false")
	}

	// Store a state with UpdateAvailable=true.
	app.updateState.Store(&UpdateState{UpdateAvailable: true})
	if !app.snapshotUpdateAvailable() {
		t.Errorf("snapshotUpdateAvailable after Store(update=true) = false")
	}

	// Store a state with UpdateAvailable=false.
	app.updateState.Store(&UpdateState{UpdateAvailable: false})
	if app.snapshotUpdateAvailable() {
		t.Errorf("snapshotUpdateAvailable after Store(update=false) = true")
	}
}

// Test 5b: the tray refresh helper receives the up-to-date visual
// state. Since we cannot drive systray.* under test, we only assert
// the observer API used to feed the tray goroutine is callable and
// pure.
func TestTrayRefreshObserverHookIsCallable(t *testing.T) {
	app := NewApp()
	app.trayRefreshCh = make(chan struct{}, 1)
	app.updateState.Store(&UpdateState{UpdateAvailable: true})

	// Observer plumbing: setUpdateStateObserver lets Task 2 subscribe
	// to update-state changes (notification helper). Nil observer must
	// be safe to invoke.
	var called atomic.Int32
	app.setUpdateStateObserver(func(s UpdateState) {
		if s.UpdateAvailable {
			called.Add(1)
		}
	})

	// Simulate a state change that runs through the observer.
	app.applyUpdateCheckResult(UpdateState{
		CurrentVersion:  "3.0.0",
		LatestVersion:   "3.0.1",
		UpdateAvailable: true,
		LastCheckedAt:   time.Now().UTC().Format(time.RFC3339),
		Enabled:         true,
	}, nil)

	if called.Load() < 1 {
		t.Error("update-state observer must be called on applyUpdateCheckResult")
	}
}
