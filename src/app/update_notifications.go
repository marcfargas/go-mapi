//go:build windows

package main

import (
	"sync"

	toast "git.sr.ht/~jackmordaunt/go-toast/v2"
)

// update_notifications.go owns the notify-only reaction to an update
// becoming available on the tray/notification surface.
//
// Scope boundary (locked by phase CONTEXT.md + plan threat model):
//
//   - D-03: this surface NEVER downloads, stages, launches, quits-and-
//     installs, or replaces a binary. The only action it exposes is
//     "open the release page in the user's default browser."
//   - D-04: update-check failures are silent. If the fetch returned
//     an error, applyUpdateCheckResult preserves the prior user-visible
//     state; the tracker observes the resulting snapshot and, because
//     UpdateAvailable is not flipped, does not fire a notification.
//   - Scope split: the tray notification side points only at the GitHub
//     release page. The direct stable installer URL is reserved for the
//     in-app update panel owned by plan 11-03.
//
// The plan struct is deliberately narrow — no Exec, Launch, Install,
// Replace, Quit, Staged, or Run fields — so D-03 regressions cannot
// slip in through struct growth. The unit test
// TestNoSelfUpdateSurface reflects across the struct and fails if any
// such field name appears.

// updateNotificationAction is a single clickable action on the toast.
// `URL` is the only effect contract — clicking opens it in the user's
// default browser via openUpdateReleasePage, which itself swallows
// browser failures silently per D-04.
type updateNotificationAction struct {
	Label string
	URL   string
}

// updateNotificationPlan is a pure description of the toast we would
// push. Kept as data (not a Notification) so the helper stays
// testable without a COM activator, and so the D-03 guard test can
// reflect across the field set.
type updateNotificationPlan struct {
	Title   string
	Body    string
	Actions []updateNotificationAction
}

// buildUpdateNotificationPlan returns the plan for an update-available
// state, or nil when no notification should fire (UpdateAvailable=false).
// Returning nil on !UpdateAvailable is how D-04 silent-failure is
// enforced at the helper level — a failed fetch that preserves prior
// UpdateAvailable=false simply never produces a plan.
func buildUpdateNotificationPlan(s UpdateState) *updateNotificationPlan {
	if !s.UpdateAvailable {
		return nil
	}
	url := s.LatestReleaseURL
	if url == "" {
		// Fallback: the repo's releases page. Never the installer URL —
		// that link lives in the in-app panel per D-02.
		url = "https://github.com/" + gitHubOwner + "/" + gitHubRepo + "/releases"
	}
	title := "go-mapi update available"
	body := "Version " + s.LatestVersion + " is ready on GitHub."
	return &updateNotificationPlan{
		Title: title,
		Body:  body,
		Actions: []updateNotificationAction{
			{Label: "Download", URL: url},
		},
	}
}

// updateNotificationTracker remembers whether an update has already been
// announced to the user so repeated observations of the same available
// release do not spam toasts. Re-fires only when:
//
//   - UpdateAvailable flips from false → true, OR
//   - LatestVersion changes while still UpdateAvailable=true (so a
//     deferred 3.0.1 toast is refreshed when 3.0.2 arrives).
//
// Transitioning to UpdateAvailable=false resets the tracker so the next
// flip-to-true fires again — supports users who install manually and
// then continue running the app through a future release.
type updateNotificationTracker struct {
	mu           sync.Mutex
	dispatch     func(*updateNotificationPlan)
	lastVersion  string
	lastAvailable bool
}

// newUpdateNotificationTracker builds a tracker around a dispatch
// function. `dispatch` is called with a non-nil plan whenever the
// tracker decides a notification should fire. Passing nil dispatch is
// a programming error — callers must wrap the real toast push.
func newUpdateNotificationTracker(dispatch func(*updateNotificationPlan)) *updateNotificationTracker {
	return &updateNotificationTracker{dispatch: dispatch}
}

// Observe is called on every UpdateState merge (see applyUpdateCheckResult's
// observer fan-out). Thread-safe: serialized by the tracker mutex.
func (t *updateNotificationTracker) Observe(s UpdateState) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if !s.UpdateAvailable {
		// Reset: next flip-to-true will fire again.
		t.lastAvailable = false
		t.lastVersion = ""
		return
	}

	// Decide whether this observation is a new signal to the user.
	shouldFire := false
	switch {
	case !t.lastAvailable:
		// Flip from not-available → available.
		shouldFire = true
	case s.LatestVersion != t.lastVersion:
		// Same availability but a newer LatestVersion was published.
		shouldFire = true
	}

	// Always remember the latest observed state so the next decision
	// can dedupe correctly.
	t.lastAvailable = true
	t.lastVersion = s.LatestVersion

	if !shouldFire {
		return
	}
	plan := buildUpdateNotificationPlan(s)
	if plan == nil {
		// Defensive: buildUpdateNotificationPlan returns nil only when
		// UpdateAvailable=false, which we've already filtered out.
		return
	}
	if t.dispatch != nil {
		t.dispatch(plan)
	}
}

// wireUpdateNotifications installs the production notification path:
// a tracker that dispatches to pushUpdateNotification (which pushes a
// real Windows toast) and a state observer that drives the tracker
// from the App's updateStateObserver fan-out.
//
// Called from startup after initToasts has run; safe to skip in tests.
func (a *App) wireUpdateNotifications() {
	a.wireUpdateNotificationsWith(func(plan *updateNotificationPlan) {
		pushUpdateNotification(a, plan)
	})
}

// wireUpdateNotificationsWith is the test seam for wireUpdateNotifications.
// Allows unit tests to inject a counting dispatcher and assert that the
// observer is correctly wired without pushing a real toast.
func (a *App) wireUpdateNotificationsWith(dispatch func(*updateNotificationPlan)) {
	tracker := newUpdateNotificationTracker(dispatch)
	a.setUpdateStateObserver(tracker.Observe)
}

// pushUpdateNotification is the production dispatch: it builds a
// Windows toast for the plan and pushes it through the existing toast
// subsystem (toast_windows.go). Click-through on the body opens the
// release URL via openUpdateReleasePage (which handles the browser
// open and silent-failure case).
//
// We piggyback on the existing AUMID/activator/icon configuration so
// no new COM registration is needed. The tag is stable across a
// session so the toast replaces itself in Action Center if a newer
// release is announced during the same session.
func pushUpdateNotification(a *App, plan *updateNotificationPlan) {
	if plan == nil {
		return
	}
	url := ""
	if len(plan.Actions) > 0 {
		url = plan.Actions[0].URL
	}
	// Use the same ActivationType + argument format as other toasts so
	// handleToastAction can pick up the click. We route through a
	// dedicated "open-update-url" action that calls openUpdateReleasePage
	// via the App binding.
	n := toast.Notification{
		AppID: activeAUMID(),
		Title: plan.Title,
		Body:  plan.Body,
		Icon:  toastIconPath(mustExePath()),
		// ActivationType Foreground + arguments → handleToastAction.
		ActivationType:      toast.Foreground,
		ActivationArguments: "action=open-update",
		Actions: []toast.Action{
			{
				Type:      toast.Protocol,
				Content:   plan.Actions[0].Label,
				Arguments: url,
			},
		},
	}
	if err := shimPushWithTagGroup(activeAUMID(), n, "update-available", toastGroup); err != nil {
		// D-04 invariant: failure to push the toast is NOT surfaced to
		// the user. Log only.
		logInfo("updates: notification push failed (silent per D-04): %v", err)
	}
}
