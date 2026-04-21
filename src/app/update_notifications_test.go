//go:build windows

package main

import (
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// ---------------------------------------------------------------------
// Phase 11 Plan 02 — Task 2 tests: update-available notification helper.
//
// Invariants under test:
//   - D-03: helper NEVER launches an installer, NEVER quits-and-installs,
//     NEVER replaces a binary. The only action exposed is "open release
//     page in browser."
//   - D-04: update-check failures do NOT trigger a notification.
//   - REL-04: notification fires only when UpdateAvailable flips true,
//     and it carries exactly one Download action.
//   - Scope: the tray notification surface does NOT expose the direct
//     stable installer URL — that link lives in the in-app panel
//     (reserved for 11-03). The tray/notification side points only at
//     the GitHub release page.
// ---------------------------------------------------------------------

// Test 1: when update state flips to available, the notification helper
// produces exactly one Download action and the target is the release
// page (never the stable installer URL).
func TestUpdateNotificationDownloadActionOpensReleasePage(t *testing.T) {
	state := UpdateState{
		CurrentVersion:   "3.0.0",
		LatestVersion:    "3.0.1",
		LatestReleaseURL: "https://github.com/marcfargas/go-mapi/releases/tag/v3.0.1",
		InstallerURL:     installerDownloadURL,
		UpdateAvailable:  true,
	}

	plan := buildUpdateNotificationPlan(state)
	if plan == nil {
		t.Fatal("buildUpdateNotificationPlan: got nil for an available update")
	}
	if len(plan.Actions) != 1 {
		t.Fatalf("expected exactly 1 Download action, got %d (%+v)", len(plan.Actions), plan.Actions)
	}
	act := plan.Actions[0]
	if !strings.EqualFold(act.Label, "Download") {
		t.Errorf("action label = %q, want %q (case-insensitive)", act.Label, "Download")
	}
	if act.URL != state.LatestReleaseURL {
		t.Errorf("action URL = %q, want release page %q (not the installer URL)",
			act.URL, state.LatestReleaseURL)
	}
	// Explicit guard: the notification side must NEVER point at the
	// direct installer URL — that affordance is reserved for the in-app
	// update panel (11-03).
	if act.URL == installerDownloadURL {
		t.Error("Download action on tray notification must not point at the stable installer URL (reserved for in-app panel)")
	}
	// Title/body carry update language so the toast is comprehensible.
	if !strings.Contains(strings.ToLower(plan.Body+plan.Title), "update") {
		t.Errorf("notification text must mention update; title=%q body=%q", plan.Title, plan.Body)
	}
	if !strings.Contains(plan.Body, state.LatestVersion) {
		t.Errorf("notification body must mention latest version %q; got %q", state.LatestVersion, plan.Body)
	}
}

// Test 1b: with no LatestReleaseURL recorded, the fallback URL is the
// repo's releases landing page — still never the installer.
func TestUpdateNotificationFallsBackToReleasesLandingPage(t *testing.T) {
	state := UpdateState{
		CurrentVersion:  "3.0.0",
		LatestVersion:   "3.0.1",
		InstallerURL:    installerDownloadURL,
		UpdateAvailable: true,
		// LatestReleaseURL intentionally empty.
	}
	plan := buildUpdateNotificationPlan(state)
	if plan == nil {
		t.Fatal("buildUpdateNotificationPlan: got nil for an available update")
	}
	if len(plan.Actions) != 1 {
		t.Fatalf("expected exactly 1 Download action, got %d", len(plan.Actions))
	}
	url := plan.Actions[0].URL
	if url == installerDownloadURL {
		t.Error("fallback must not point at the installer URL")
	}
	if !strings.Contains(url, "github.com/marcfargas/go-mapi/releases") {
		t.Errorf("fallback URL should point at the repo releases page; got %q", url)
	}
}

// Test 2: the notification helper NEVER produces an installer-launch
// action, quit-and-install action, or any shell-exec surface.
func TestNoSelfUpdateSurface(t *testing.T) {
	state := UpdateState{
		CurrentVersion:   "3.0.0",
		LatestVersion:    "3.0.1",
		LatestReleaseURL: "https://github.com/marcfargas/go-mapi/releases/tag/v3.0.1",
		InstallerURL:     installerDownloadURL,
		UpdateAvailable:  true,
	}
	plan := buildUpdateNotificationPlan(state)
	if plan == nil {
		t.Fatal("got nil plan")
	}
	// Reflect across the plan struct to ensure no exec / install /
	// replace / launch fields exist — a guard against future drift.
	v := reflect.ValueOf(*plan)
	typ := v.Type()
	forbidden := []string{"exec", "launch", "install", "run", "replace", "quit", "staged"}
	for i := 0; i < typ.NumField(); i++ {
		name := strings.ToLower(typ.Field(i).Name)
		for _, bad := range forbidden {
			if strings.Contains(name, bad) {
				t.Errorf("updateNotificationPlan must not expose field %q (D-03)", typ.Field(i).Name)
			}
		}
	}
	// Verify action labels never include self-update language.
	for _, a := range plan.Actions {
		lbl := strings.ToLower(a.Label)
		for _, bad := range []string{"install", "quit and install", "quit & install", "run"} {
			if strings.Contains(lbl, bad) {
				t.Errorf("action label %q violates D-03 (no self-update surface)", a.Label)
			}
		}
	}
}

// Test 3: an update-check failure produces NO notification plan.
// The helper treats fetch failure as silent (D-04).
func TestUpdateNotificationSilentOnFailure(t *testing.T) {
	// Simulated "no update available" outcome after a failed fetch —
	// applyUpdateCheckResult preserved the prior state, so from the
	// notifier's perspective the current snapshot has UpdateAvailable=false.
	state := UpdateState{
		CurrentVersion:  "3.0.0",
		LatestVersion:   "", // no fetch ever succeeded
		InstallerURL:    installerDownloadURL,
		UpdateAvailable: false,
	}
	if plan := buildUpdateNotificationPlan(state); plan != nil {
		t.Errorf("buildUpdateNotificationPlan with UpdateAvailable=false must return nil; got %+v", plan)
	}
}

// Test 4: notification dispatcher fires ONLY when UpdateAvailable flips
// from false to true. Repeated state emissions with UpdateAvailable=true
// must NOT re-fire the toast (prevents notification spam).
func TestUpdateNotificationFiresOnlyOnFlipToAvailable(t *testing.T) {
	var calls atomic.Int32
	dispatch := func(*updateNotificationPlan) { calls.Add(1) }

	tracker := newUpdateNotificationTracker(dispatch)

	// Initial: not available → no call.
	tracker.Observe(UpdateState{UpdateAvailable: false, CurrentVersion: "3.0.0"})
	if calls.Load() != 0 {
		t.Fatalf("no-update state must not fire; calls=%d", calls.Load())
	}

	// Flip to available → one call.
	avail := UpdateState{
		UpdateAvailable:  true,
		CurrentVersion:   "3.0.0",
		LatestVersion:    "3.0.1",
		LatestReleaseURL: "https://example.invalid/v3.0.1",
	}
	tracker.Observe(avail)
	if calls.Load() != 1 {
		t.Fatalf("flip-to-available must fire once; calls=%d", calls.Load())
	}

	// Same availability emitted again (e.g. cadence recheck confirms
	// same release) → no re-fire.
	tracker.Observe(avail)
	if calls.Load() != 1 {
		t.Errorf("repeated available state must not re-fire; calls=%d", calls.Load())
	}

	// Flip back to not-available (e.g. user upgraded; next check shows
	// no newer release), then flip to available again → one more call.
	tracker.Observe(UpdateState{UpdateAvailable: false, CurrentVersion: "3.0.1"})
	tracker.Observe(UpdateState{
		UpdateAvailable:  true,
		CurrentVersion:   "3.0.1",
		LatestVersion:    "3.0.2",
		LatestReleaseURL: "https://example.invalid/v3.0.2",
	})
	if calls.Load() != 2 {
		t.Errorf("second flip-to-available must fire again; calls=%d", calls.Load())
	}
}

// Test 5: newer LatestVersion arriving while still UpdateAvailable=true
// re-fires the notification (so users don't miss a v3.0.3 after sitting
// on a deferred v3.0.1 toast).
func TestUpdateNotificationRefiresOnNewerVersion(t *testing.T) {
	var calls atomic.Int32
	dispatch := func(*updateNotificationPlan) { calls.Add(1) }

	tracker := newUpdateNotificationTracker(dispatch)
	tracker.Observe(UpdateState{
		UpdateAvailable: true,
		CurrentVersion:  "3.0.0",
		LatestVersion:   "3.0.1",
	})
	if calls.Load() != 1 {
		t.Fatalf("first available state must fire; calls=%d", calls.Load())
	}
	// Same version → no re-fire.
	tracker.Observe(UpdateState{
		UpdateAvailable: true,
		CurrentVersion:  "3.0.0",
		LatestVersion:   "3.0.1",
	})
	if calls.Load() != 1 {
		t.Errorf("same latest version must not re-fire; calls=%d", calls.Load())
	}
	// Newer version → re-fire.
	tracker.Observe(UpdateState{
		UpdateAvailable: true,
		CurrentVersion:  "3.0.0",
		LatestVersion:   "3.0.2",
	})
	if calls.Load() != 2 {
		t.Errorf("newer version must re-fire; calls=%d", calls.Load())
	}
}

// Test 6 (wiring): App.wireUpdateNotifications registers a state
// observer that drives the tracker. This confirms Task 2 is wired into
// the applyUpdateCheckResult fan-out from Task 1.
func TestUpdateNotificationWiredToUpdateStateObserver(t *testing.T) {
	var calls atomic.Int32
	app := NewApp()
	// Install a test dispatcher so we do not actually push a toast.
	app.wireUpdateNotificationsWith(func(*updateNotificationPlan) { calls.Add(1) })

	// Simulate an applyUpdateCheckResult-like fan-out by invoking the
	// observer directly — we do not want to spin up the full service
	// layer in this test.
	if app.updateStateObserver == nil {
		t.Fatal("wireUpdateNotifications must install updateStateObserver")
	}
	app.updateStateObserver(UpdateState{
		UpdateAvailable:  true,
		CurrentVersion:   "3.0.0",
		LatestVersion:    "3.0.1",
		LatestReleaseURL: "https://example.invalid/v3.0.1",
	})
	if calls.Load() != 1 {
		t.Errorf("observer dispatch must call tracker; calls=%d", calls.Load())
	}
}

// Test 7: guards rapid flips — a tracker that sees alternating flips
// within < minInterval only fires once per flip to avoid toast storm.
// This is optional-by-contract: we expect minInterval to exist but let
// the default be 0 (no rate limit) to keep behaviour simple. Assert
// that the default tracker fires on every distinct flip (no debouncing).
func TestUpdateNotificationDefaultHasNoDebouncing(t *testing.T) {
	var calls atomic.Int32
	tracker := newUpdateNotificationTracker(func(*updateNotificationPlan) { calls.Add(1) })
	// Two flips in quick succession with distinct latest versions.
	tracker.Observe(UpdateState{UpdateAvailable: true, LatestVersion: "3.0.1"})
	time.Sleep(5 * time.Millisecond)
	tracker.Observe(UpdateState{UpdateAvailable: true, LatestVersion: "3.0.2"})
	if calls.Load() != 2 {
		t.Errorf("default tracker must fire per distinct flip; calls=%d", calls.Load())
	}
}
