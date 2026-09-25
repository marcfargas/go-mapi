package main

import (
	"net/url"
	"strings"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

const storeUpdatesURI = "ms-windows-store://downloadsandupdates"

// publicMachineStatus is supplied by a platform-specific, read-only reader.
// A missing or untrusted publication is never evidence of managed updates.
type publicMachineStatus struct {
	Status         mapi.PublicStatusV2
	Identity       mapi.InstalledStatusIdentity
	ServiceRunning bool
	Trusted        bool
}

func effectiveUpdateState(raw UpdateState, channel string, machine publicMachineStatus) UpdateState {
	state := raw
	state.ManagedSystemUpdate = machine.Trusted && mapi.ManagedSystemUpdateEffective(machine.Status, machine.Identity, machine.ServiceRunning, time.Now().UTC())
	if state.ManagedSystemUpdate {
		state.InterceptorUpdateAvailable = false
	}
	state.DistributionChannel = channel
	state.UpdateActionURL = ""
	state.UpdateActionLabel = ""
	state.UpdateGuidance = ""
	switch channel {
	case "standalone":
		if state.UpdateAvailable && !validFixedAppRoute(state.InstallerURL) {
			state.InstallerURL = ""
			state.LatestReleaseURL = ""
		}
		if state.UpdateAvailable && state.InstallerURL != "" {
			state.UpdateActionURL = state.InstallerURL
			state.UpdateActionLabel = "Open download page"
		}
	case "store":
		// Store users use their established Store channel; a standalone
		// installer route is never offered to them.
		state.InstallerURL = ""
		state.LatestReleaseURL = ""
		if state.UpdateAvailable {
			state.UpdateActionURL = storeUpdatesURI
			state.UpdateActionLabel = "Open Microsoft Store updates"
		}
	case "machine":
		state.InstallerURL = ""
		state.LatestReleaseURL = ""
		state.UpdateAvailable = false
		state.InterceptorUpdateAvailable = false
		if machine.Trusted && (machine.Status.Health == "repair-required" || machine.Status.Code == "repair-required") {
			state.UpdateGuidance = "The machine installation needs repair. Contact your administrator."
		} else {
			state.UpdateGuidance = "This machine installation is maintained by your administrator."
		}
	default:
		state.InstallerURL = ""
		state.LatestReleaseURL = ""
		state.UpdateAvailable = false
		state.InterceptorUpdateAvailable = false
		state.UpdateGuidance = "The installation channel could not be verified. Contact your administrator for update guidance."
	}
	return state
}

func validUpdateActionURL(state UpdateState) bool {
	switch state.DistributionChannel {
	case "standalone":
		return state.UpdateActionURL == state.InstallerURL && validFixedAppRoute(state.UpdateActionURL)
	case "store":
		return state.UpdateActionURL == storeUpdatesURI
	case "":
		// Legacy callers of the tray helper pass its pre-policy snapshot.
		// Production emissions always carry a channel.
		return state.UpdateActionURL == "" && validFixedAppRoute(state.InstallerURL)
	default:
		return false
	}
}

func updateAction(state UpdateState) (label, url string, valid bool) {
	if !validUpdateActionURL(state) {
		return "", "", false
	}
	if state.DistributionChannel == "" {
		return "Download", state.InstallerURL, true
	}
	return state.UpdateActionLabel, state.UpdateActionURL, true
}

// This is a portable mirror of the fixed route guard. The Windows action
// validates the route again immediately before opening the browser.
func validFixedAppRoute(value string) bool {
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "https" || u.Host != "go-mapi.app" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.RawPath != "" {
		return false
	}
	parts := strings.Split(u.Path, "/")
	return len(parts) == 5 && parts[1] == "downloads" && parts[2] == "app" && mapi.IsStrictReleaseVersion(parts[3]) && parts[4] == "x64"
}
