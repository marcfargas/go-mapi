package main

import "time"

// updateCheckWindow is the app background check floor.
const updateCheckWindow = 24 * time.Hour

// UpdateState is the single source of truth that tray and frontend render
// from. Intentionally metadata-only — no fields for download paths,
// staged installers, or replacement flags. If you find yourself wanting
// to add one, revisit D-03; that belongs in a later phase, not here.
type UpdateState struct {
	// CurrentVersion is main.Version at process start (ldflags-injected,
	// see main.go). Always populated.
	CurrentVersion string `json:"currentVersion"`

	// LatestVersion is the tag/version reported by the most recent
	// successful release fetch. Empty string if no successful fetch has
	// happened yet or the most recent fetch failed.
	LatestVersion string `json:"latestVersion"`

	// LatestReleaseURL is retained for Wails API compatibility and points at
	// the same validated, versioned first-party route as InstallerURL.
	LatestReleaseURL string `json:"latestReleaseUrl"`

	// InstallerURL is the validated, versioned go-mapi.app route shown in the
	// update panel. The route redirects to the signed release artifact.
	InstallerURL string `json:"installerUrl"`

	// UpdateAvailable is true iff LatestVersion > CurrentVersion. Pure
	// derived signal — tray/frontend treat this as the "show banner"
	// trigger.
	UpdateAvailable bool `json:"updateAvailable"`

	// LastCheckedAt is the RFC3339 timestamp of the most recent check
	// attempt (success OR failure). Empty string when never checked.
	// Refreshed even on fetch failure so cadence advances and users are
	// not stuck in a hot-loop of failing re-fetches.
	LastCheckedAt string `json:"lastCheckedAt"`
	// LastSuccessfulAt is in-memory proof that this process received a valid
	// complete first-party response. An attempted or failed check is not proof.
	LastSuccessfulAt    string `json:"lastSuccessfulAt"`
	DistributionChannel string `json:"distributionChannel"`
	UpdateGuidance      string `json:"updateGuidance"`
	ManagedSystemUpdate bool   `json:"managedSystemUpdate"`
	UpdateActionURL     string `json:"updateActionUrl"`
	UpdateActionLabel   string `json:"updateActionLabel"`

	// Enabled mirrors AppSettings.UpdateChecksEnabled so tray/frontend
	// can render the toggle state without reading settings themselves.
	Enabled bool `json:"enabled"`

	// InterceptorLatestVersion and InterceptorUpdateAvailable are advisory
	// component status only. They never authorize or trigger installation.
	InterceptorLatestVersion   string `json:"interceptorLatestVersion"`
	InterceptorUpdateAvailable bool   `json:"interceptorUpdateAvailable"`
	Compatibility              string `json:"compatibility"`
}
