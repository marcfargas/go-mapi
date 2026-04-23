package main

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
	wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// automode owns the auto-draft drain goroutine. Lifecycle:
//   - newAutomode + start called from App.startup
//   - wakes on bridge.AutomodeWake OR a 30s safety tick
//   - checks mode + paused; idle if either gate is closed
//   - for each queued email not already in flight and not backlog-skipped:
//     MakeAuthenticatedGmailCall → watcher.MarkProcessed → emit auto-draft-result
//   - halts drain on first invalid_grant (D-10: one summary toast, not per-email spam)
//   - stops on shutdownCtx or done channel close
//
// T-3 mitigation: inflight map prevents double-draft when the automode goroutine
// and a toast-activation concurrent path both try to draft the same email.
// T-5 mitigation: drain halts immediately on first ErrInvalidGrant; auth state
// is already cleaned up by MakeAuthenticatedGmailCall atomically.
type automode struct {
	app  *App
	wake <-chan struct{}

	done      chan struct{}
	closeOnce sync.Once

	inflightMu sync.Mutex
	inflight   map[string]struct{}

	// emit is pluggable for tests — newAutomode uses wruntime.EventsEmit;
	// tests inject a capturing function via newAutomodeWithEmitter.
	emit func(event string, payload any)
}

func newAutomode(app *App, wake <-chan struct{}) *automode {
	return newAutomodeWithEmitter(app, wake, func(event string, payload any) {
		wruntime.EventsEmit(app.ctx, event, payload)
	})
}

func newAutomodeWithEmitter(app *App, wake <-chan struct{}, emit func(string, any)) *automode {
	return &automode{
		app:      app,
		wake:     wake,
		done:     make(chan struct{}),
		inflight: make(map[string]struct{}),
		emit:     emit,
	}
}

func (m *automode) start() { go m.loop() }

func (m *automode) stop() { m.closeOnce.Do(func() { close(m.done) }) }

func (m *automode) loop() {
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-m.done:
			return
		case <-m.app.shutdownCtx.Done():
			return
		case <-m.wake:
			m.drain()
		case <-tick.C:
			// Safety ticker: catches any missed wake signals (e.g. signals that
			// arrived before automode started, or lost to a timing edge).
			m.drain()
		}
	}
}

// drain processes queued emails while in auto-draft mode and not paused.
// Returns early on:
//   - paused
//   - mode != auto-draft
//   - shutdown
//   - first invalid_grant (terminal for this drain — user must re-auth, D-10)
func (m *automode) drain() {
	if m.app.isPaused() || m.app.getMode() != "auto-draft" {
		return
	}
	if m.app.watcher == nil {
		return
	}
	for _, e := range m.app.watcher.Snapshot() {
		if m.app.shutdownCtx.Err() != nil {
			return
		}
		// Re-check gates mid-drain (user may have paused or switched mode).
		if m.app.isPaused() || m.app.getMode() != "auto-draft" {
			return
		}
		if m.app.isBacklogSkipped(e.Id) {
			continue
		}
		if !m.tryAcquire(e.Id) {
			// Already being drafted by a concurrent drain or toast-activation.
			continue
		}
		err := m.draftOne(e)
		m.release(e.Id)
		if err != nil && errors.Is(err, ErrInvalidGrant) {
			// Terminal — halt drain. markBacklogSkipped was already called
			// inside draftOne; ReAuthBanner surfaces via MakeAuthenticatedGmailCall
			// emitting auth-changed. D-10: one summary toast per drain, not per-email.
			emitSummaryInvalidGrantToast(m.app)
			return
		}
	}
}

func (m *automode) tryAcquire(id string) bool {
	m.inflightMu.Lock()
	defer m.inflightMu.Unlock()
	if _, ok := m.inflight[id]; ok {
		return false
	}
	m.inflight[id] = struct{}{}
	return true
}

func (m *automode) release(id string) {
	m.inflightMu.Lock()
	defer m.inflightMu.Unlock()
	delete(m.inflight, id)
}

// draftOne runs one Gmail draft via MakeAuthenticatedGmailCall. Emits
// auto-draft-result per outcome. On invalid_grant, marks the email as
// backlog-skipped so post-re-auth drains leave it for manual review (D-10).
//
// Privacy: logs only the 8-char id prefix + error category (QUAL-03).
// Never logs subject / body / recipient. T-9-09 compliance.
func (m *automode) draftOne(e mapi.EmailWithId) error {
	// T-9-06: per-call timeout. 30s chosen per RESEARCH §4; Gmail p95 is ~1-3s.
	// shutdownCtx ensures app quit cancels in-flight calls.
	ctx, cancel := context.WithTimeout(m.app.shutdownCtx, 30*time.Second)
	defer cancel()

	callErr := m.app.MakeAuthenticatedGmailCall(ctx, func(token string) (int, error) {
		gc := mapi.NewGmailClientWithBase(token, gmailBaseURLOverride)
		_, err := gc.CreateDraft(e.Message)
		if err != nil {
			// RESEARCH §4 line 640-650: CreateDraft does not expose HTTP status code.
			// "token expired" text means 401 (see gmail.go:91); everything else is 500.
			// MakeAuthenticatedGmailCall uses 401 to trigger refresh-and-retry-once.
			if err.Error() == "token expired" {
				return 401, err
			}
			return 500, err
		}
		return 200, nil
	})

	if callErr != nil {
		category := classifyAutomodeError(callErr)
		// QUICK-260423-tk6: log the raw error alongside the category so
		// "attachment not found" and similar concrete failures surface in
		// app.log instead of being demoted to the opaque "gmail" catchall.
		// Privacy note: the error text never contains subject/body/recipient;
		// it comes from GmailClient / os.Stat which handle local paths only.
		logError("automode: draft %s failed: category=%s err=%v",
			safeIDPrefix(e.Id), category, callErr)
		if category == "signed-out" {
			// D-10: mark so post-re-auth drains skip this backlog row.
			m.app.markBacklogSkipped(e.Id)
		}
		m.emit("auto-draft-result", map[string]any{
			"emailId":       e.Id,
			"success":       false,
			"errorCategory": category,
			"reason":        callErr.Error(),
		})
		// Error toast fires regardless of window state (D-11: errors always surface).
		emitErrorToast(m.app, category, e.Id)
		return callErr
	}

	if err := m.app.watcher.MarkProcessed(e.Id); err != nil {
		// MarkProcessed is idempotent (Task 1) — a non-nil error here is unexpected.
		// Log and let the row linger; the queue-update event will refresh the UI.
		logError("automode: MarkProcessed %s: %v", safeIDPrefix(e.Id), err)
	}
	// Draft-success toast: only fires when window is hidden (D-11). Subject safe per
	// UI-SPEC copywriting; no body text / recipient email exposed (QUAL-03).
	if e.Message != nil {
		emitDraftSuccessToast(m.app, e.Message.Subject, e.Id)
	}
	// Clear arrival + error toasts for this email from Action Center (NOTIF-05).
	clearToastForEmail(e.Id)
	m.emit("auto-draft-result", map[string]any{
		"emailId": e.Id,
		"success": true,
	})
	return nil
}

// classifyAutomodeError maps errors to the three UI categories per D-09.
// Precedence: invalid_grant / not-authenticated → "signed-out";
// timeout / connection error → "network"; catchall → "gmail".
func classifyAutomodeError(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, ErrInvalidGrant) || errors.Is(err, ErrNotAuthenticated) {
		return "signed-out"
	}
	var netErr interface{ Timeout() bool }
	if errors.As(err, &netErr) && netErr.Timeout() {
		return "network"
	}
	// Context deadline exceeded or connection refused are network-level failures.
	if errors.Is(err, context.DeadlineExceeded) {
		return "network"
	}
	return "gmail"
}

// safeIDPrefix returns the first 8 chars of an id or the whole string if
// shorter, for privacy-safe logging. Never logs the full 64-char hash (QUAL-03).
func safeIDPrefix(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// gmailBaseURLOverride is a package-level var that tests can set to point
// draftOne at a local httptest.Server. Production code leaves it empty
// (NewGmailClientWithBase falls back to GmailAPIBase when empty).
var gmailBaseURLOverride string
