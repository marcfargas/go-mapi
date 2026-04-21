//go:build windows

package main

import (
	"context"
	"fmt"
	"time"

	"github.com/pkg/browser"
)

// tray_update.go hosts the Phase 11 pure helpers and App methods that the
// tray menu uses to render current-version / last-checked status rows and
// to wire the persisted "Check for updates" toggle + manual "Check for
// updates now" action.
//
// Invariants enforced here:
//   - D-05: the toggle writes through the App settings path (saveSettings
//     atomic writer); no parallel persistence.
//   - D-06: manual checks bypass the 24h cadence gate by calling
//     CheckForUpdatesNow directly.
//   - D-04: manual-check failures stay silent — we log, but lastErrorMsg
//     is NOT mutated.
//   - D-07: the status helpers are pure (UpdateState → string) so they
//     can be unit-tested without a live systray host.
//   - T-9-10: any tray render call remains on the tray goroutine. These
//     helpers are formatters only; they never touch systray.*.

// formatUpdateCurrentVersionLabel renders the "Version <x>" row for the
// tray menu (D-07). Returns "Version unknown" when the cached state has
// no version yet — the app has not finished initialising, but we must
// never render an error-looking label (D-04 shape applies: tray stays
// calm on missing data).
func formatUpdateCurrentVersionLabel(s UpdateState) string {
	v := s.CurrentVersion
	if v == "" {
		v = "unknown"
	}
	return "Version " + v
}

// formatUpdateLastCheckedLabel renders the "Last checked: <when>" row for
// the tray menu (D-07). `now` is injected so tests can drive relative
// time deterministically.
//
// Shape:
//   - empty / unparsable LastCheckedAt → "Last checked: never"
//   - < 60s ago                        → "Last checked: just now"
//   - < 60m ago                        → "Last checked: Xm ago"
//   - < 24h ago                        → "Last checked: Xh ago"
//   - otherwise                        → "Last checked: Xd ago"
//
// The label is intentionally vague on the high end — we show days, not
// "months ago" — because the 24h cadence gate means a running app will
// never render older than ~1 day unless checks have been disabled, in
// which case the stale value is still informative.
func formatUpdateLastCheckedLabel(s UpdateState, now time.Time) string {
	if s.LastCheckedAt == "" {
		return "Last checked: never"
	}
	t, err := time.Parse(time.RFC3339, s.LastCheckedAt)
	if err != nil {
		// Malformed input on disk is treated as "never" — do NOT render
		// a parse-error string into the tray (D-04 shape).
		return "Last checked: never"
	}
	diff := now.Sub(t)
	switch {
	case diff < time.Minute:
		return "Last checked: just now"
	case diff < time.Hour:
		return fmt.Sprintf("Last checked: %dm ago", int(diff/time.Minute))
	case diff < 24*time.Hour:
		return fmt.Sprintf("Last checked: %dh ago", int(diff/time.Hour))
	default:
		return fmt.Sprintf("Last checked: %dd ago", int(diff/(24*time.Hour)))
	}
}

// snapshotUpdateAvailable is a fast read for the tray refresh path:
// the update-available flag lives behind the atomic pointer cache, so
// computeTrayVisual can consult it without reaching through the full
// GetUpdateState copy on every tick.
func (a *App) snapshotUpdateAvailable() bool {
	state := a.updateState.Load()
	if state == nil {
		return false
	}
	return state.UpdateAvailable
}

// setUpdateChecksEnabled flips the "Check for updates" preference,
// persisting through saveSettings (D-05 — no second persistence path)
// and signalling the tray so the checkbox + status rows re-render.
// Mirrors setMode's pattern (see app.go) so the single-writer invariant
// on settings.go is preserved.
//
// Exposed as a Wails binding by SetUpdateChecksEnabled below so the
// frontend can share the same path (future-proofing for 11-03 / any
// later settings panel per CONTEXT Deferred Ideas).
func (a *App) setUpdateChecksEnabled(enabled bool) error {
	a.settingsMu.Lock()
	a.settings.UpdateChecksEnabled = enabled
	s := a.settings
	a.settingsMu.Unlock()
	if err := saveSettings(s); err != nil {
		return fmt.Errorf("settings: persist update-checks-enabled: %w", err)
	}
	// Refresh the cached UpdateState so tray/frontend reads pick up the
	// new flag immediately — syncUpdateEnabledIntoState also emits the
	// update-state-changed event so the frontend subscriber (11-03) sees
	// the change without a round-trip through GetUpdateState.
	a.syncUpdateEnabledIntoState(enabled)
	// Tray refresh so the checkbox + status rows reflect the toggle.
	a.signalTrayRefresh()
	return nil
}

// SetUpdateChecksEnabled is the Wails binding form of setUpdateChecksEnabled.
// Safe to call from the frontend or from tray-goroutine menu handlers; the
// persistence path (saveSettings) is the single-writer atomic-save channel
// for this field.
func (a *App) SetUpdateChecksEnabled(enabled bool) error {
	return a.setUpdateChecksEnabled(enabled)
}

// runTrayManualUpdateCheck is the tray-goroutine wrapper around
// CheckForUpdatesNow (D-06). It ensures:
//
//   - the fetch runs on a goroutine, so the tray message pump never
//     blocks on network IO (T-9-10 + T-9-11);
//   - on success the tray is signalled to re-render status rows so the
//     user immediately sees "Last checked: just now" and any new
//     update-available indicator;
//   - on failure the error is logged, the prior user-visible state is
//     preserved by applyUpdateCheckResult (D-04), and NO tray error is
//     raised.
//
// Returns the underlying fetch error so callers (tests, future-binding)
// can observe failure paths; production tray click handlers ignore it.
func (a *App) runTrayManualUpdateCheck(ctx context.Context) error {
	// Fall back to a bounded timeout if the caller passes a nil context
	// (shouldn't happen in production — tray uses a.shutdownCtx — but
	// keep it defensive for tests).
	if ctx == nil {
		ctx = context.Background()
	}
	err := a.CheckForUpdatesNow(ctx)
	// Always signal the tray refresh, even on failure: LastCheckedAt
	// advances inside CheckNow so the "Last checked" row should update.
	a.signalTrayRefresh()
	if err != nil {
		// D-04: log only. The applyUpdateCheckResult path inside
		// CheckForUpdatesNow already preserves the prior user-visible
		// LatestVersion / UpdateAvailable.
		logInfo("updates: manual check failed (silent per D-04): %v", err)
	}
	return err
}

// setUpdateStateObserver installs a callback that fires whenever
// applyUpdateCheckResult merges a new UpdateState. Separate from
// updateStateEmitter (which is reserved for the Wails event emission)
// so tray/notification code can observe without racing the frontend
// wiring. At most one observer at a time — callers wanting multiple
// subscribers should fan out themselves.
func (a *App) setUpdateStateObserver(fn func(UpdateState)) {
	a.updateStateObserver = fn
}

// handleUpdateDownloadAction is the tray Download menu entry point
// (REL-04 + D-03): opens the release page via the user's browser and
// NEVER launches an installer, quits-and-installs, or replaces the
// running binary. Task 2 reuses the same helper from
// update_notifications.go so the tray and the notification surface
// converge on one download-action implementation.
func (a *App) handleUpdateDownloadAction() {
	openUpdateReleasePage(a.GetUpdateState())
}

// openUpdateReleasePage opens the user's default browser at the release
// page for the cached LatestVersion. Falls back to the project's GitHub
// releases landing page if no LatestReleaseURL has been recorded yet —
// we still never route the user to the stable installer URL here, since
// the tray surface is the "learn more / browse" affordance; the direct
// installer link lives in the in-app update panel owned by 11-03
// (D-02).
//
// D-03 invariant: this function only opens a URL. It never downloads,
// stages, launches, or replaces a binary.
// D-04 invariant: a failed browser.Open is logged and swallowed — no
// tray error is raised on missing default-browser registration.
func openUpdateReleasePage(s UpdateState) {
	url := s.LatestReleaseURL
	if url == "" {
		// Fallback: the repo's releases page, which always works even
		// when no LatestReleaseURL has been captured yet (e.g. a stale
		// install with no successful fetch since upgrade).
		url = "https://github.com/" + gitHubOwner + "/" + gitHubRepo + "/releases"
	}
	if err := browser.OpenURL(url); err != nil {
		logInfo("updates: open release page (silent per D-04): %v", err)
	}
}
