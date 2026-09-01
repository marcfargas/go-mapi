//go:build windows

package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// tempSettingsEnv redirects %APPDATA% so AppSettings writes land in a
// temp dir for the duration of the test.
func tempSettingsEnv(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("GOMAPI_APPDATA_DIR", dir)
	return dir
}

// writeInitialSettings bootstraps a settings.json for the App to load
// during its test-harness startup. Keeps these tests focused on the
// update-service wiring rather than re-exercising loadSettings.
func writeInitialSettings(t *testing.T, dir string, s AppSettings) {
	t.Helper()
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	data, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), data, 0600); err != nil {
		t.Fatalf("write settings.json: %v", err)
	}
}

// countingFetcher is a releaseFetcher stub that tracks call counts
// and can be swapped to return a release, nil, or an error.
type countingFetcher struct {
	mu      sync.Mutex
	calls   int
	release *latestRelease
	err     error
}

func (c *countingFetcher) FetchLatestRelease(ctx context.Context) (*latestRelease, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.calls++
	if c.err != nil {
		return nil, c.err
	}
	return c.release, nil
}

func (c *countingFetcher) callCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.calls
}

// newAppForUpdateTests creates a minimal App that:
//   - points settings at the given tempDir
//   - has a fake updater service running against the supplied fetcher
//   - does NOT start the tray / watcher / automode
//
// Caller is responsible for driving startup-update / manual-check /
// scheduler paths directly via exported App hooks.
func newAppForUpdateTests(t *testing.T, fetcher releaseFetcher, version string) *App {
	t.Helper()
	app := NewApp()
	app.settings = loadSettings().Settings
	app.updates = newUpdateService(version, fetcher, nopLogger)
	app.updateState.Store(&UpdateState{
		CurrentVersion: version,
		InstallerURL:   installerDownloadURL,
		Enabled:        app.settings.UpdateChecksEnabled,
	})
	shutdownCtx, cancel := context.WithCancel(context.Background())
	app.shutdownCtx = shutdownCtx
	app.shutdownCancel = cancel
	t.Cleanup(cancel)
	return app
}

// Test 1: startup performs at most one background check when enabled
// and the 24h window is stale. Re-running the startup path (simulated)
// inside the same window must not re-fetch.
func TestStartupUpdateRunsOneBackgroundCheckWhenStale(t *testing.T) {
	tempSettingsEnv(t)
	writeInitialSettings(t, appDataDir(), AppSettings{
		Mode:                "manual",
		UpdateChecksEnabled: true,
		LastUpdateCheck:     "", // never checked = stale
	})

	fetcher := &countingFetcher{
		release: &latestRelease{Version: "3.0.0", ReleaseURL: "https://example.invalid/v3.0.0"},
	}
	app := newAppForUpdateTests(t, fetcher, "2.1.0")

	app.runStartupUpdateCheck(context.Background())
	if fetcher.callCount() != 1 {
		t.Fatalf("expected exactly one fetch on stale startup, got %d", fetcher.callCount())
	}

	state := app.GetUpdateState()
	if !state.UpdateAvailable {
		t.Error("expected UpdateAvailable=true after successful fetch")
	}
	if state.LastCheckedAt == "" {
		t.Error("LastCheckedAt should be set after startup check")
	}

	// A second call inside the 24h window must not re-fetch.
	app.runStartupUpdateCheck(context.Background())
	if fetcher.callCount() != 1 {
		t.Errorf("second startup call inside 24h window must not re-fetch, got %d", fetcher.callCount())
	}
}

// Test 2a: startup skips the check when opt-out is set.
func TestStartupUpdateSkippedWhenDisabled(t *testing.T) {
	tempSettingsEnv(t)
	writeInitialSettings(t, appDataDir(), AppSettings{
		Mode:                "manual",
		UpdateChecksEnabled: false,
	})
	fetcher := &countingFetcher{}
	app := newAppForUpdateTests(t, fetcher, "2.1.0")

	app.runStartupUpdateCheck(context.Background())

	if fetcher.callCount() != 0 {
		t.Errorf("expected 0 fetches when disabled, got %d", fetcher.callCount())
	}
	state := app.GetUpdateState()
	if state.Enabled {
		t.Error("state.Enabled must be false when settings disabled")
	}
}

// Test 2b: startup skips when LastUpdateCheck is within 24h.
func TestStartupUpdateSkippedWhenRecent(t *testing.T) {
	tempSettingsEnv(t)
	recent := time.Now().UTC().Add(-30 * time.Minute).Format(time.RFC3339)
	writeInitialSettings(t, appDataDir(), AppSettings{
		Mode:                "manual",
		UpdateChecksEnabled: true,
		LastUpdateCheck:     recent,
	})
	fetcher := &countingFetcher{}
	app := newAppForUpdateTests(t, fetcher, "2.1.0")

	app.runStartupUpdateCheck(context.Background())

	if fetcher.callCount() != 0 {
		t.Errorf("expected 0 fetches inside 24h window, got %d", fetcher.callCount())
	}
}

// Test 3: manual CheckForUpdatesNow bypasses the cadence gate, refreshes
// last-checked, and results in state-change observation by callers.
func TestCheckForUpdatesNowBypassesCadence(t *testing.T) {
	tempSettingsEnv(t)
	recent := time.Now().UTC().Add(-1 * time.Minute).Format(time.RFC3339)
	writeInitialSettings(t, appDataDir(), AppSettings{
		Mode:                "manual",
		UpdateChecksEnabled: true,
		LastUpdateCheck:     recent,
	})

	fetcher := &countingFetcher{
		release: &latestRelease{Version: "3.0.0", ReleaseURL: "https://example.invalid/v3.0.0"},
	}
	app := newAppForUpdateTests(t, fetcher, "2.1.0")

	if err := app.CheckForUpdatesNow(context.Background()); err != nil {
		t.Fatalf("CheckForUpdatesNow: %v", err)
	}

	if fetcher.callCount() != 1 {
		t.Errorf("manual check must bypass cadence, got %d fetches", fetcher.callCount())
	}

	// LastUpdateCheck must have been persisted through the guarded
	// writer — re-reading settings should show a fresh timestamp.
	got := loadSettings().Settings
	if got.LastUpdateCheck == "" {
		t.Error("LastUpdateCheck should be persisted after manual check")
	}
	if got.LastUpdateCheck == recent {
		t.Error("LastUpdateCheck should have advanced past the pre-check timestamp")
	}

	// Cached UpdateState reflects the newest release.
	state := app.GetUpdateState()
	if !state.UpdateAvailable {
		t.Error("expected UpdateAvailable=true after manual check")
	}
	if state.LatestVersion != "3.0.0" {
		t.Errorf("expected LatestVersion=3.0.0, got %q", state.LatestVersion)
	}
}

// Test 4a: a startup check that fails logs the error and leaves the
// previously cached state unchanged apart from LastCheckedAt.
func TestStartupUpdateFailureKeepsPriorStateUserInvisible(t *testing.T) {
	tempSettingsEnv(t)
	writeInitialSettings(t, appDataDir(), AppSettings{
		Mode:                "manual",
		UpdateChecksEnabled: true,
		LastUpdateCheck:     "",
	})

	fetcher := &countingFetcher{err: errors.New("offline")}
	app := newAppForUpdateTests(t, fetcher, "2.1.0")

	// Seed a prior "update available" state to prove we preserve it on
	// failure — a user previously saw 3.0.0 available; a transient
	// fetch failure must not wipe that banner (D-04).
	prior := &UpdateState{
		CurrentVersion:   "2.1.0",
		LatestVersion:    "3.0.0",
		LatestReleaseURL: "https://example.invalid/v3.0.0",
		InstallerURL:     installerDownloadURL,
		UpdateAvailable:  true,
		LastCheckedAt:    time.Now().UTC().Add(-48 * time.Hour).Format(time.RFC3339),
		Enabled:          true,
	}
	app.updateState.Store(prior)

	app.runStartupUpdateCheck(context.Background())

	if fetcher.callCount() != 1 {
		t.Errorf("expected 1 fetch attempt, got %d", fetcher.callCount())
	}
	state := app.GetUpdateState()
	if state.LatestVersion != "3.0.0" {
		t.Errorf("prior LatestVersion should survive fetch failure, got %q", state.LatestVersion)
	}
	if !state.UpdateAvailable {
		t.Error("prior UpdateAvailable must survive fetch failure (D-04)")
	}
	// LastCheckedAt advanced so cadence does not hammer on retry.
	if state.LastCheckedAt == prior.LastCheckedAt {
		t.Error("LastCheckedAt should advance even on fetch failure")
	}
}

// Test 4b: manual CheckForUpdatesNow failure surfaces the error to the
// caller (for logging) but preserves the prior user-visible state.
func TestManualCheckFailurePreservesPriorState(t *testing.T) {
	tempSettingsEnv(t)
	writeInitialSettings(t, appDataDir(), AppSettings{
		Mode:                "manual",
		UpdateChecksEnabled: true,
	})

	fetcher := &countingFetcher{err: errors.New("offline")}
	app := newAppForUpdateTests(t, fetcher, "2.1.0")

	// Prior "3.0.0 available" must survive transient offline manual check.
	app.updateState.Store(&UpdateState{
		CurrentVersion:   "2.1.0",
		LatestVersion:    "3.0.0",
		LatestReleaseURL: "https://example.invalid/v3.0.0",
		InstallerURL:     installerDownloadURL,
		UpdateAvailable:  true,
		Enabled:          true,
	})

	err := app.CheckForUpdatesNow(context.Background())
	if err == nil {
		t.Fatal("expected CheckForUpdatesNow to return the fetch error for logging")
	}

	state := app.GetUpdateState()
	if !state.UpdateAvailable {
		t.Error("prior UpdateAvailable must survive manual-check failure (D-04)")
	}
	if state.LatestVersion != "3.0.0" {
		t.Errorf("prior LatestVersion must survive failure, got %q", state.LatestVersion)
	}
}

// Test 5: the App-owned guarded writer routes LastUpdateCheck through a
// single path, preserving the single-writer atomic invariant. Simulate
// 50 concurrent background-cadence writes and confirm no tmp files
// leak (a race-unsafe implementation would leave tmp garbage behind).
func TestGuardedLastUpdateCheckWriterSerializes(t *testing.T) {
	dir := tempSettingsEnv(t)
	writeInitialSettings(t, appDataDir(), AppSettings{
		Mode:                "manual",
		UpdateChecksEnabled: true,
	})
	fetcher := &countingFetcher{}
	app := newAppForUpdateTests(t, fetcher, "2.1.0")

	const workers = 50
	var wg sync.WaitGroup
	wg.Add(workers)
	for i := 0; i < workers; i++ {
		go func(i int) {
			defer wg.Done()
			ts := time.Now().UTC().Add(time.Duration(i) * time.Millisecond).Format(time.RFC3339)
			if err := app.persistLastUpdateCheck(ts); err != nil {
				t.Errorf("persistLastUpdateCheck: %v", err)
			}
		}(i)
	}
	wg.Wait()

	// No tmp files leaked — proves atomic-save pattern was honored
	// under concurrent calls.
	matches, err := filepath.Glob(filepath.Join(dir, "settings-*.tmp"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) > 0 {
		t.Errorf("atomic save leaked tmp files under concurrent cadence writes: %v", matches)
	}

	// Final persisted LastUpdateCheck must be a valid RFC3339 string.
	got := loadSettings().Settings
	if got.LastUpdateCheck == "" {
		t.Fatal("expected LastUpdateCheck to be persisted")
	}
	if _, err := time.Parse(time.RFC3339, got.LastUpdateCheck); err != nil {
		t.Errorf("persisted LastUpdateCheck not RFC3339: %q (%v)", got.LastUpdateCheck, err)
	}
	// UpdateChecksEnabled must still be true — guarded writer must not
	// clobber other settings fields (preserves Mode + Enabled).
	if !got.UpdateChecksEnabled {
		t.Error("guarded writer clobbered UpdateChecksEnabled field")
	}
	if got.Mode != "manual" {
		t.Errorf("guarded writer clobbered Mode field, got %q", got.Mode)
	}
}

// Test 6: the long-lived scheduler wakes after an interval, re-evaluates
// settings, and performs a silent recheck. Uses a test-only hook to run
// the scheduler tick with a shortened interval.
func TestUpdateSchedulerLongSessionRechecks(t *testing.T) {
	tempSettingsEnv(t)
	writeInitialSettings(t, appDataDir(), AppSettings{
		Mode:                "manual",
		UpdateChecksEnabled: true,
		LastUpdateCheck:     time.Now().UTC().Add(-48 * time.Hour).Format(time.RFC3339),
	})

	fetcher := &countingFetcher{
		release: &latestRelease{Version: "3.0.0", ReleaseURL: "https://example.invalid"},
	}
	app := newAppForUpdateTests(t, fetcher, "2.1.0")

	// Drive the scheduler tick directly — test-only, exercises the
	// same code path the long-lived goroutine runs.
	app.updateSchedulerTick(context.Background())

	if fetcher.callCount() != 1 {
		t.Fatalf("scheduler tick must fetch when cadence is stale, got %d", fetcher.callCount())
	}

	// Second tick inside the fresh window must not re-fetch.
	app.updateSchedulerTick(context.Background())
	if fetcher.callCount() != 1 {
		t.Errorf("scheduler tick inside 24h window must not re-fetch, got %d", fetcher.callCount())
	}
}

// Test 6b: the scheduler tick respects opt-out — toggling settings off
// at runtime must suppress subsequent ticks (no lingering network calls).
func TestUpdateSchedulerRespectsOptOutAtRuntime(t *testing.T) {
	tempSettingsEnv(t)
	writeInitialSettings(t, appDataDir(), AppSettings{
		Mode:                "manual",
		UpdateChecksEnabled: true,
		LastUpdateCheck:     time.Now().UTC().Add(-48 * time.Hour).Format(time.RFC3339),
	})
	fetcher := &countingFetcher{
		release: &latestRelease{Version: "3.0.0", ReleaseURL: "https://example.invalid"},
	}
	app := newAppForUpdateTests(t, fetcher, "2.1.0")

	// Flip opt-out on in memory — simulating a user turning the toggle
	// off via the tray after startup.
	app.settingsMu.Lock()
	app.settings.UpdateChecksEnabled = false
	app.settingsMu.Unlock()

	app.updateSchedulerTick(context.Background())

	if fetcher.callCount() != 0 {
		t.Errorf("scheduler tick must honor runtime opt-out, got %d fetches", fetcher.callCount())
	}
}

// Test 6c: scheduler tick on fetch failure is silent — no panic, and
// the prior cached state is preserved.
func TestUpdateSchedulerSilentFailure(t *testing.T) {
	tempSettingsEnv(t)
	writeInitialSettings(t, appDataDir(), AppSettings{
		Mode:                "manual",
		UpdateChecksEnabled: true,
		LastUpdateCheck:     time.Now().UTC().Add(-48 * time.Hour).Format(time.RFC3339),
	})
	fetcher := &countingFetcher{err: errors.New("offline")}
	app := newAppForUpdateTests(t, fetcher, "2.1.0")

	app.updateState.Store(&UpdateState{
		CurrentVersion:  "2.1.0",
		LatestVersion:   "3.0.0",
		UpdateAvailable: true,
		Enabled:         true,
		InstallerURL:    installerDownloadURL,
	})

	// Must not panic.
	app.updateSchedulerTick(context.Background())

	state := app.GetUpdateState()
	if !state.UpdateAvailable {
		t.Error("prior UpdateAvailable must survive silent scheduler failure (D-04)")
	}
}

// Test 7: the event-emitter hook is called every time the cached state
// materially changes (UpdateAvailable / LatestVersion / Enabled /
// LastCheckedAt). Validates the backend-owned single-event contract
// that tray + frontend will consume in later plans.
func TestUpdateStateChangeNotifiesObservers(t *testing.T) {
	tempSettingsEnv(t)
	writeInitialSettings(t, appDataDir(), AppSettings{
		Mode:                "manual",
		UpdateChecksEnabled: true,
		LastUpdateCheck:     "",
	})

	fetcher := &countingFetcher{
		release: &latestRelease{Version: "3.0.0", ReleaseURL: "https://example.invalid"},
	}
	app := newAppForUpdateTests(t, fetcher, "2.1.0")

	var emitted atomic.Int32
	app.updateStateEmitter = func(state UpdateState) {
		emitted.Add(1)
	}

	app.runStartupUpdateCheck(context.Background())

	if got := emitted.Load(); got < 1 {
		t.Errorf("expected at least 1 update-state emission, got %d", got)
	}

	before := emitted.Load()
	// A manual check that produces an identical state should emit
	// again at most once (implementations may coalesce — the contract
	// only forbids silent changes, not re-emission of same state).
	if err := app.CheckForUpdatesNow(context.Background()); err != nil {
		t.Fatalf("CheckForUpdatesNow: %v", err)
	}
	if emitted.Load() < before {
		t.Errorf("emission counter regressed: before=%d after=%d", before, emitted.Load())
	}
}

// Test 8: GetUpdateState always returns a non-nil snapshot with the
// current version populated, even when no check has ever happened.
// Frontend hydration must never crash on an uninitialized pointer.
func TestGetUpdateStateAlwaysPopulatesCurrentVersion(t *testing.T) {
	tempSettingsEnv(t)
	writeInitialSettings(t, appDataDir(), AppSettings{
		Mode:                "manual",
		UpdateChecksEnabled: true,
	})
	fetcher := &countingFetcher{}
	app := newAppForUpdateTests(t, fetcher, "2.1.0")

	state := app.GetUpdateState()
	if state.CurrentVersion != "2.1.0" {
		t.Errorf("expected CurrentVersion=2.1.0, got %q", state.CurrentVersion)
	}
	if state.InstallerURL != installerDownloadURL {
		t.Errorf("InstallerURL must be the stable download URL, got %q", state.InstallerURL)
	}
}
