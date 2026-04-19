//go:build windows

package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/marcfargas/go-mapi/internal/mapi"
)

// ---- test helpers ----

// makeTestEmailFile writes a valid email JSON to dir/filename and returns the full path.
func makeTestEmailFile(t *testing.T, dir, filename, subject, ts string) string {
	t.Helper()
	msg := mapi.MailMessage{
		Version:    1,
		Timestamp:  ts,
		Subject:    subject,
		Body:       "body for " + subject,
		BodyFormat: "plain",
		Recipients: mapi.Recipients{
			To: []mapi.Recipient{{Address: "to@example.com"}},
		},
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	path := filepath.Join(dir, filename)
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatalf("os.WriteFile(%s): %v", path, err)
	}
	return path
}

// nopWatcherCallback discards all callbacks (used when the bridge is not needed in tests).
type nopWatcherCallback struct{}

func (n *nopWatcherCallback) OnQueueChanged(_ []mapi.EmailWithId) {}
func (n *nopWatcherCallback) OnError(_ error)                     {}

// captureEmitter records emitted events for test assertions.
type captureEmitter struct {
	mu     sync.Mutex
	events []capturedEvent
}

type capturedEvent struct {
	event   string
	payload any
}

func (c *captureEmitter) emit(event string, payload any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.events = append(c.events, capturedEvent{event: event, payload: payload})
}

func (c *captureEmitter) all() []capturedEvent {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]capturedEvent, len(c.events))
	copy(out, c.events)
	return out
}

func (c *captureEmitter) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.events)
}

// waitCount polls until the emitter has at least n events or times out.
func (c *captureEmitter) waitCount(t *testing.T, n int, d time.Duration) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if c.count() >= n {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("emitter: waited %v for %d events, got %d", d, n, c.count())
}

// seedEmailAndWait writes an email JSON to watchDir and polls until the watcher
// registers it. Returns the email's queue ID.
func seedEmailAndWait(t *testing.T, ew *mapi.EmailWatcher, watchDir, filename, subject, ts string) string {
	t.Helper()
	makeTestEmailFile(t, watchDir, filename, subject, ts)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		for _, e := range ew.Snapshot() {
			if e.Message.Subject == subject {
				return e.Id
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("seedEmailAndWait: %q did not appear in watcher snapshot within 3s", subject)
	return ""
}

// setupAutomode builds an App + automode for test use.
// gmailHandler: handler for the local Gmail stub (nil = 200 OK with draft response).
// tokenHandler: handler for the token endpoint (nil = no token server; uses in-memory valid token).
// Returns (app, watchDir, captureEmitter, automode).
func setupAutomode(t *testing.T, gmailHandler, tokenHandler http.HandlerFunc) (*App, string, *captureEmitter, *automode) {
	t.Helper()

	watchDir := t.TempDir()

	// Gmail stub server.
	if gmailHandler == nil {
		gmailHandler = func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{"id":"draft-test-123"}`))
		}
	}
	gmailSrv := httptest.NewServer(gmailHandler)
	t.Cleanup(gmailSrv.Close)
	gmailBaseURLOverride = gmailSrv.URL
	t.Cleanup(func() { gmailBaseURLOverride = "" })

	// Token stub server (optional).
	if tokenHandler != nil {
		tokenSrv := httptest.NewServer(tokenHandler)
		t.Cleanup(tokenSrv.Close)
		tokenEndpointOverride = tokenSrv.URL
		t.Cleanup(func() { tokenEndpointOverride = "" })
	}

	// App with fake keyring and valid in-memory tokens.
	store := newFakeKeyringStore()
	app := NewApp()
	app.auth = NewAuthManagerWithStore(store)
	app.auth.tokens = &OAuthTokens{
		AccessToken:  "valid-access-token",
		RefreshToken: "valid-refresh-token",
		TokenType:    "Bearer",
		Expiry:       time.Now().Add(1 * time.Hour),
	}
	app.settings.Mode = "auto-draft"

	// shutdownCtx: never cancelled for unit tests.
	shutdownCtx, shutdownCancel := context.WithCancel(context.Background())
	app.shutdownCtx = shutdownCtx
	app.shutdownCancel = shutdownCancel
	t.Cleanup(shutdownCancel)

	// Real EmailWatcher pointed at watchDir.
	cb := &nopWatcherCallback{}
	ew, err := mapi.NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher: %v", err)
	}
	t.Cleanup(func() { ew.Stop() })
	if err := ew.Start(); err != nil {
		t.Fatalf("ew.Start: %v", err)
	}
	app.watcher = ew

	cap := &captureEmitter{}
	wake := make(chan struct{}, 1)
	am := newAutomodeWithEmitter(app, wake, cap.emit)

	return app, watchDir, cap, am
}

// ---- Tests ----

// TestAutomodeSuccessPath: mode=auto-draft, 1 email, Gmail 200 → success emit + file removed.
func TestAutomodeSuccessPath(t *testing.T) {
	app, watchDir, cap, am := setupAutomode(t, nil, nil)

	id := seedEmailAndWait(t, app.watcher, watchDir, "email1.json", "Success Test", "2024-01-01T00:00:00Z")

	am.drain()

	cap.waitCount(t, 1, 2*time.Second)
	events := cap.all()
	if len(events) != 1 {
		t.Fatalf("expected 1 auto-draft-result event, got %d", len(events))
	}
	m, ok := events[0].payload.(map[string]any)
	if !ok {
		t.Fatalf("payload is not map[string]any: %T", events[0].payload)
	}
	if m["success"] != true {
		t.Errorf("expected success=true, got %v", m["success"])
	}
	if m["emailId"] != id {
		t.Errorf("expected emailId=%q, got %v", id, m["emailId"])
	}
	// Email removed from queue (MarkProcessed ran).
	for _, e := range app.watcher.Snapshot() {
		if e.Id == id {
			t.Error("email still in snapshot after success — MarkProcessed should have removed it")
		}
	}
}

// TestAutomodeInvalidGrantHaltsDrainAndBacklogSkips: 2 emails, token endpoint
// returns invalid_grant → exactly 1 result emitted, drain halts, first id backlog-skipped.
func TestAutomodeInvalidGrantHaltsDrainAndBacklogSkips(t *testing.T) {
	tokenHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		_, _ = w.Write([]byte(`{"error":"invalid_grant"}`))
	})
	// Gmail returns 401 so MakeAuthenticatedGmailCall triggers the token refresh path.
	gmailHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
		_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
	})

	app, watchDir, cap, am := setupAutomode(t, gmailHandler, tokenHandler)

	// Expire the token so refreshIfNeededLocked hits the token endpoint.
	app.auth.tokens.Expiry = time.Now().Add(-time.Minute)

	id1 := seedEmailAndWait(t, app.watcher, watchDir, "email1.json", "Email One", "2024-01-01T00:00:00Z")
	_ = seedEmailAndWait(t, app.watcher, watchDir, "email2.json", "Email Two", "2024-01-02T00:00:00Z")

	am.drain()

	// Wait for the one event and confirm a second does NOT appear.
	cap.waitCount(t, 1, 3*time.Second)
	time.Sleep(100 * time.Millisecond)

	events := cap.all()
	if len(events) != 1 {
		t.Fatalf("expected exactly 1 auto-draft-result (drain halts on invalid_grant), got %d", len(events))
	}
	m, _ := events[0].payload.(map[string]any)
	if m["success"] != false {
		t.Errorf("expected success=false, got %v", m["success"])
	}
	if m["errorCategory"] != "signed-out" {
		t.Errorf("expected errorCategory=signed-out, got %v", m["errorCategory"])
	}
	// First email must be backlog-skipped.
	if !app.isBacklogSkipped(id1) {
		t.Errorf("expected id1=%q to be backlog-skipped", id1)
	}
	// Second email still in queue (drain halted before it).
	found := false
	for _, e := range app.watcher.Snapshot() {
		if e.Message.Subject == "Email Two" {
			found = true
			break
		}
	}
	if !found {
		t.Error("email two should still be in snapshot (drain halted before reaching it)")
	}
}

// TestAutomodeNetworkError: Gmail endpoint closes connection → network-like error emitted.
func TestAutomodeNetworkError(t *testing.T) {
	gmailHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Hijack and close to force a transport-level error.
		conn, _, _ := w.(http.Hijacker).Hijack()
		conn.Close()
	})

	app, watchDir, cap, am := setupAutomode(t, gmailHandler, nil)
	_ = seedEmailAndWait(t, app.watcher, watchDir, "email1.json", "Network Error Test", "2024-01-01T00:00:00Z")

	am.drain()

	cap.waitCount(t, 1, 3*time.Second)
	events := cap.all()
	if len(events) == 0 {
		t.Fatal("expected at least 1 auto-draft-result event")
	}
	m, _ := events[0].payload.(map[string]any)
	if m["success"] != false {
		t.Errorf("expected success=false, got %v", m["success"])
	}
	// Connection-closed may classify as "network" or "gmail" depending on Go's HTTP stack.
	cat, _ := m["errorCategory"].(string)
	if cat != "network" && cat != "gmail" {
		t.Errorf("expected errorCategory network or gmail for connection-closed, got %q", cat)
	}
}

// TestAutomodeGmail5xx: Gmail endpoint returns 500 → errorCategory:"gmail".
func TestAutomodeGmail5xx(t *testing.T) {
	gmailHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
		_, _ = w.Write([]byte(`{"error":"internal"}`))
	})

	app, watchDir, cap, am := setupAutomode(t, gmailHandler, nil)
	_ = seedEmailAndWait(t, app.watcher, watchDir, "email1.json", "Gmail 5xx Test", "2024-01-01T00:00:00Z")

	am.drain()

	cap.waitCount(t, 1, 2*time.Second)
	events := cap.all()
	if len(events) == 0 {
		t.Fatal("expected 1 auto-draft-result event")
	}
	m, _ := events[0].payload.(map[string]any)
	if m["errorCategory"] != "gmail" {
		t.Errorf("expected errorCategory=gmail for 500 response, got %v", m["errorCategory"])
	}
}

// TestAutomodePauseRespected: paused=true → drain returns immediately, zero emits.
func TestAutomodePauseRespected(t *testing.T) {
	app, watchDir, cap, am := setupAutomode(t, nil, nil)
	_ = seedEmailAndWait(t, app.watcher, watchDir, "email1.json", "Pause Test", "2024-01-01T00:00:00Z")

	app.SetPaused(true)
	am.drain()

	time.Sleep(50 * time.Millisecond)
	if cap.count() != 0 {
		t.Errorf("expected 0 emits when paused, got %d", cap.count())
	}
	// File should still be present.
	if len(app.watcher.Snapshot()) == 0 {
		t.Error("email should still be in snapshot when paused")
	}
}

// TestAutomodeManualModeRespected: mode="manual" → drain returns immediately, zero emits.
func TestAutomodeManualModeRespected(t *testing.T) {
	app, watchDir, cap, am := setupAutomode(t, nil, nil)
	app.settings.Mode = "manual"

	_ = seedEmailAndWait(t, app.watcher, watchDir, "email1.json", "Manual Mode Test", "2024-01-01T00:00:00Z")

	am.drain()

	time.Sleep(50 * time.Millisecond)
	if cap.count() != 0 {
		t.Errorf("expected 0 emits in manual mode, got %d", cap.count())
	}
}

// TestAutomodeInflightPreventsDoubleDraft: pre-populate inflight with an id,
// drain() skips that email (tryAcquire returns false).
func TestAutomodeInflightPreventsDoubleDraft(t *testing.T) {
	app, watchDir, cap, am := setupAutomode(t, nil, nil)
	id := seedEmailAndWait(t, app.watcher, watchDir, "email1.json", "Inflight Test", "2024-01-01T00:00:00Z")

	// Pre-populate inflight for this email.
	am.inflightMu.Lock()
	am.inflight[id] = struct{}{}
	am.inflightMu.Unlock()

	am.drain()

	time.Sleep(50 * time.Millisecond)
	if cap.count() != 0 {
		t.Errorf("expected 0 emits for inflight email, got %d", cap.count())
	}
	// Email still in queue.
	found := false
	for _, e := range app.watcher.Snapshot() {
		if e.Id == id {
			found = true
			break
		}
	}
	if !found {
		t.Error("inflight email should still be in queue")
	}
}

// TestAutomodeBacklogSkipPersistsAcrossReauth: email-A is backlog-skipped;
// a second drain processes email-B but not A; A remains skipped afterward.
func TestAutomodeBacklogSkipPersistsAcrossReauth(t *testing.T) {
	app, watchDir, cap, am := setupAutomode(t, nil, nil)

	idA := seedEmailAndWait(t, app.watcher, watchDir, "emailA.json", "Email A", "2024-01-01T00:00:00Z")

	// Mark A as backlog-skipped (simulating what invalid_grant would have done).
	app.markBacklogSkipped(idA)

	// First drain: A is skipped, zero emits.
	am.drain()
	time.Sleep(50 * time.Millisecond)
	if cap.count() != 0 {
		t.Errorf("expected 0 emits for backlog-skipped email, got %d", cap.count())
	}

	// Seed email-B (simulating a new arrival after re-auth).
	_ = seedEmailAndWait(t, app.watcher, watchDir, "emailB.json", "Email B", "2024-01-02T00:00:00Z")

	// Second drain: B should succeed, A should still be skipped.
	am.drain()
	cap.waitCount(t, 1, 2*time.Second)

	events := cap.all()
	if len(events) != 1 {
		t.Fatalf("expected 1 auto-draft-result (for email B only), got %d", len(events))
	}
	m, _ := events[0].payload.(map[string]any)
	if m["success"] != true {
		t.Errorf("expected success=true for email B, got %v", m["success"])
	}
	if m["emailId"] == idA {
		t.Error("email A should not have been drafted (backlog-skipped)")
	}
	// A still in backlogSkip after the successful B drain.
	if !app.isBacklogSkipped(idA) {
		t.Error("email A should remain in backlogSkip after re-auth drain")
	}
}

// TestPruneBacklogSkipRemovesAbsentIds: pruneBacklogSkip retains only ids present in currentIds.
func TestPruneBacklogSkipRemovesAbsentIds(t *testing.T) {
	app := NewApp()
	app.markBacklogSkipped("a")
	app.markBacklogSkipped("b")

	app.pruneBacklogSkip(map[string]struct{}{"a": {}})

	if !app.isBacklogSkipped("a") {
		t.Error("id 'a' should remain in backlogSkip")
	}
	if app.isBacklogSkipped("b") {
		t.Error("id 'b' should have been pruned (not in currentIds)")
	}
}

// TestClassifyAutomodeError: table-driven unit test for the error classifier.
func TestClassifyAutomodeError(t *testing.T) {
	cases := []struct {
		name    string
		err     error
		wantCat string
	}{
		{"nil", nil, ""},
		{"ErrInvalidGrant direct", ErrInvalidGrant, "signed-out"},
		{"ErrNotAuthenticated direct", ErrNotAuthenticated, "signed-out"},
		{"ErrInvalidGrant wrapped via Join", errors.Join(errors.New("outer"), ErrInvalidGrant), "signed-out"},
		{"DeadlineExceeded", context.DeadlineExceeded, "network"},
		{"generic gmail 500", errors.New("Gmail API error (500): internal"), "gmail"},
		{"non-wrapped string", errors.New("some random error"), "gmail"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := classifyAutomodeError(tc.err)
			if got != tc.wantCat {
				t.Errorf("classifyAutomodeError(%v) = %q, want %q", tc.err, got, tc.wantCat)
			}
		})
	}
}
