//go:build windows

package main

// toast_windows.go is the Windows implementation of the toast notification
// subsystem for go-mapi. Uses jackmordaunt/go-toast/v2 for COM activator
// registration and toast_shim_windows.go for Tag/Group/ClearToast (NOTIF-05).
//
// Privacy (QUAL-03): Toast payloads include ONLY:
//   - Title: sender display name (never email address if display name exists)
//   - Body: subject + "📎 N attachment(s)" (never body text, filenames, recipients)
//   - Icon: absolute path to app icon (not email content)
//
// D-11: Arrival + draft-success toasts suppressed when main window is visible
// and focused; error toasts always fire.

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"

	toast "git.sr.ht/~jackmordaunt/go-toast/v2"
	"github.com/marcfargas/go-mapi/internal/mapi"
)

// initToasts registers the COM activator + activation callback.
// MUST be called before any emitXxxToast call.
// Safe to call more than once; underlying library is idempotent on SetAppData.
func initToasts(a *App) error {
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("toast: resolve exe path: %w", err)
	}
	// Cache exe path for later calls.
	cachedExePath = exe

	icon := toastIconPath(exe)
	if err := toast.SetAppData(toast.AppData{
		AppID:         activeAUMID(),
		GUID:          toastActivatorGUID,
		ActivationExe: exe,
		IconPath:      icon,
	}); err != nil {
		return fmt.Errorf("toast: SetAppData: %w", err)
	}
	toast.SetActivationCallback(func(args string, _ []toast.UserData) {
		// COM thread — dispatch to a goroutine. Never do business logic here.
		go a.handleToastAction(args)
	})
	logInfo("toast: initialized (aumid=%s)", activeAUMID())
	return nil
}

// toastIconPath returns the absolute path to the app icon used in toast visuals.
// jackmordaunt/go-toast requires an absolute path; the icon must be an .ico or .png.
// We ship go-mapi.ico alongside the exe in both dev and prod layouts.
func toastIconPath(exePath string) string {
	return filepath.Join(filepath.Dir(exePath), "go-mapi.ico")
}

// cachedExePath is populated by initToasts; avoids repeated os.Executable calls.
var cachedExePath string

// mustExePath returns the cached exe path, calling os.Executable on first use.
// Panics on failure — the toast subsystem cannot function without it.
func mustExePath() string {
	if cachedExePath == "" {
		exe, err := os.Executable()
		if err != nil {
			panic(fmt.Errorf("toast: os.Executable: %w", err))
		}
		cachedExePath = exe
	}
	return cachedExePath
}

// windowFocused returns whether the main Wails window currently has input focus.
// Wails runtime does not expose a direct "is focused" query; we approximate
// by checking isVisible(). Plan 09 can refine with a Svelte-side focus listener.
func windowFocused(a *App) bool {
	return a.isVisible()
}

// emitArrivalToast fires a toast for a newly-arrived email.
// Suppressed when the main window is visible AND focused (D-11).
// Privacy: Title = sender display name; Body = subject + optional attachment count.
// NEVER includes attachment filenames, recipient list, or body text (QUAL-03).
func emitArrivalToast(a *App, e mapi.EmailWithId) {
	if a.isVisible() && windowFocused(a) {
		return
	}
	if a.isPaused() {
		return
	}
	if e.Message == nil {
		return
	}
	title := displayFrom(e.Message)
	body := e.Message.Subject
	if c := len(e.Message.Attachments); c > 0 {
		body += fmt.Sprintf("\n📎 %d attachment(s)", c)
	}
	n := toast.Notification{
		AppID:               activeAUMID(),
		Title:               title,
		Body:                body,
		Icon:                toastIconPath(mustExePath()),
		ActivationType:      toast.Foreground,
		ActivationArguments: fmt.Sprintf("action=open&emailId=%s", url.QueryEscape(e.Id)),
		Actions: []toast.Action{
			{
				Type:      toast.Foreground,
				Content:   "Create draft",
				Arguments: fmt.Sprintf("action=create-draft&emailId=%s", url.QueryEscape(e.Id)),
			},
			{
				Type:      toast.Foreground,
				Content:   "Dismiss",
				Arguments: fmt.Sprintf("action=dismiss&emailId=%s", url.QueryEscape(e.Id)),
			},
		},
	}
	if err := shimPushWithTagGroup(activeAUMID(), n, e.Id, toastGroup); err != nil {
		// Privacy-safe log: id prefix + error class only.
		logError("toast: arrival push failed for %s: %v", safeIDPrefix(e.Id), err)
	}
}

// emitDraftSuccessToast fires only when the window is hidden (D-04 + D-11).
// No action buttons — dismissible only. Subject is included per UI-SPEC copywriting.
func emitDraftSuccessToast(a *App, subject, emailID string) {
	if a.isVisible() && windowFocused(a) {
		return
	}
	if a.isPaused() {
		return
	}
	n := toast.Notification{
		AppID:               activeAUMID(),
		Title:               "Draft created: " + subject,
		Icon:                toastIconPath(mustExePath()),
		ActivationType:      toast.Foreground,
		ActivationArguments: "action=open",
	}
	// Use emailID+":success" as the tag so it's distinct from the arrival toast.
	// The ":success" toast is not cleared by clearToastForEmail — left for the
	// user to dismiss (it confirms a successful draft).
	tag := emailID + ":success"
	if err := shimPushWithTagGroup(activeAUMID(), n, tag, toastGroup); err != nil {
		logError("toast: draft-success push failed for %s: %v", safeIDPrefix(emailID), err)
	}
}

// emitErrorToast fires regardless of window state (D-11: errors always surface).
// Per D-09: error category drives the copy via toastErrorCopy.
func emitErrorToast(a *App, category, emailID string) {
	n := toast.Notification{
		AppID:               activeAUMID(),
		Title:               "go-mapi",
		Body:                toastErrorCopy(category),
		Icon:                toastIconPath(mustExePath()),
		ActivationType:      toast.Foreground,
		ActivationArguments: "action=open",
	}
	// Include emailID in tag so subsequent MarkProcessed/Delete can clear it.
	tag := emailID + ":err"
	if err := shimPushWithTagGroup(activeAUMID(), n, tag, toastGroup); err != nil {
		logError("toast: error push failed for %s: %v", safeIDPrefix(emailID), err)
	}
}

// emitSummaryInvalidGrantToast fires the D-10 one-shot summary on the first
// invalid_grant during a drain. Fires regardless of window state (error class).
func emitSummaryInvalidGrantToast(_ *App) {
	n := toast.Notification{
		AppID:               activeAUMID(),
		Title:               "go-mapi",
		Body:                toastCopySummaryInvalidGrant,
		Icon:                toastIconPath(mustExePath()),
		ActivationType:      toast.Foreground,
		ActivationArguments: "action=open",
	}
	if err := shimPushWithTagGroup(activeAUMID(), n, "summary:invalid-grant", toastGroup); err != nil {
		logError("toast: summary invalid_grant push failed: %v", err)
	}
}

// clearToastForEmail removes the toast(s) associated with a processed email
// from Action Center (NOTIF-05). Called after MarkProcessed / Delete.
// Clears the arrival toast (tag = emailID) and the error toast (tag = emailID+":err").
// The ":success" tag is NOT cleared — left for the user to acknowledge.
func clearToastForEmail(emailID string) {
	aumid := activeAUMID()
	for _, tag := range []string{emailID, emailID + ":err"} {
		if err := shimClearToast(aumid, tag, toastGroup); err != nil {
			logError("toast: clear %s failed: %v", tag, err)
		}
	}
}

// displayFrom returns a privacy-safe display string for the toast title.
// Since MAPI emails are outgoing, we show the first To recipient (name preferred
// over address) as the "To:" label, or the origin app as a fallback.
// Never logs or exposes this string beyond the toast UI (QUAL-03).
func displayFrom(msg *mapi.MailMessage) string {
	if len(msg.Recipients.To) > 0 {
		r := msg.Recipients.To[0]
		if r.Name != "" {
			return "To: " + r.Name
		}
		if r.Address != "" {
			return "To: " + r.Address
		}
	}
	if msg.OriginApp != "" {
		return msg.OriginApp
	}
	return "go-mapi"
}
