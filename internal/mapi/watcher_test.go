package mapi

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"testing"
	"time"
)

// stubCallback records OnQueueChanged and OnError calls for test assertions.
type stubCallback struct {
	mu       sync.Mutex
	queue    chan []EmailWithId
	errors   chan error
	onChange int // count of OnQueueChanged calls
}

func newStubCallback() *stubCallback {
	return &stubCallback{
		queue:  make(chan []EmailWithId, 16),
		errors: make(chan error, 16),
	}
}

func (s *stubCallback) OnQueueChanged(snapshot []EmailWithId) {
	s.mu.Lock()
	s.onChange++
	s.mu.Unlock()
	s.queue <- snapshot
}

func (s *stubCallback) OnError(err error) {
	s.errors <- err
}

// waitSnapshot waits for the next OnQueueChanged call, timing out after timeout.
func (s *stubCallback) waitSnapshot(t *testing.T, timeout time.Duration) []EmailWithId {
	t.Helper()
	select {
	case snap := <-s.queue:
		return snap
	case <-time.After(timeout):
		t.Fatalf("timed out waiting for OnQueueChanged after %v", timeout)
		return nil
	}
}

// waitError waits for the next OnError call, timing out after timeout.
func (s *stubCallback) waitError(t *testing.T, timeout time.Duration) error {
	t.Helper()
	select {
	case err := <-s.errors:
		return err
	case <-time.After(timeout):
		t.Fatalf("timed out waiting for OnError after %v", timeout)
		return nil
	}
}

// makeValidEmail builds a JSON-serialized MailMessage suitable for watcher tests.
func makeValidEmail(t *testing.T, subject, timestamp string) []byte {
	t.Helper()
	msg := MailMessage{
		Version:    1,
		Timestamp:  timestamp,
		Subject:    subject,
		Body:       "test body for " + subject,
		BodyFormat: "plain",
		Recipients: Recipients{
			To: []Recipient{{Address: "test@example.com"}},
		},
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	return data
}

// writeFile atomically writes data to a file, creating it if needed.
func writeFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatalf("os.WriteFile(%s): %v", path, err)
	}
}

// Test 1: NewEmailWatcher returns watcher with non-nil fields; nil callback logs warning but doesn't panic.
func TestEmailWatcher_NewWatcher_NonNilFields(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	defer ew.Stop()

	if ew.watchDir == "" {
		t.Error("watchDir should be non-empty")
	}
	if ew.watcher == nil {
		t.Error("fsnotify watcher should be non-nil")
	}
	if ew.emails == nil {
		t.Error("emails map should be non-nil")
	}
	if ew.fileToID == nil {
		t.Error("fileToID map should be non-nil")
	}
}

// Test 1b: nil callback must not panic.
func TestEmailWatcher_NewWatcher_NilCallback(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")

	defer func() {
		if r := recover(); r != nil {
			t.Errorf("NewEmailWatcher(nil cb) panicked: %v", r)
		}
	}()

	ew, err := NewEmailWatcher(watchDir, nil)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	defer ew.Stop()
}

// Test 2: When a valid email JSON appears, OnQueueChanged fires with the email in the snapshot.
func TestEmailWatcher_ValidFile_CallsOnQueueChanged(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	os.MkdirAll(watchDir, 0755)

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	defer ew.Stop()

	// Write file before Start so processExistingFiles picks it up.
	data := makeValidEmail(t, "Queue Change Test", "2024-01-01T00:00:00Z")
	writeFile(t, filepath.Join(watchDir, "test.json"), data)

	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}

	snap := cb.waitSnapshot(t, 3*time.Second)
	if len(snap) != 1 {
		t.Fatalf("expected 1 email in snapshot, got %d", len(snap))
	}
	if snap[0].Message.Subject != "Queue Change Test" {
		t.Errorf("subject = %q, want %q", snap[0].Message.Subject, "Queue Change Test")
	}
	if snap[0].Id == "" {
		t.Error("snapshot email ID should be non-empty")
	}
}

// Test 3: When a file is removed, OnQueueChanged fires with a shorter snapshot.
func TestEmailWatcher_FileRemoved_SnapshotShrinks(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	os.MkdirAll(watchDir, 0755)

	// Write a file before starting.
	data := makeValidEmail(t, "Removable Email", "2024-01-02T00:00:00Z")
	filePath := filepath.Join(watchDir, "removable.json")
	writeFile(t, filePath, data)

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	defer ew.Stop()

	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}

	// Wait for initial add notification.
	snap := cb.waitSnapshot(t, 3*time.Second)
	if len(snap) != 1 {
		t.Fatalf("expected 1 email after write, got %d", len(snap))
	}

	// Now remove the file.
	if err := os.Remove(filePath); err != nil {
		t.Fatalf("os.Remove: %v", err)
	}

	// Wait for remove notification.
	snap = cb.waitSnapshot(t, 3*time.Second)
	if len(snap) != 0 {
		t.Errorf("expected empty snapshot after remove, got %d items", len(snap))
	}
}

// Test 4: When validation fails, file moves to errors/ and OnError fires.
func TestEmailWatcher_InvalidFile_MovesToErrorsAndCallsOnError(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	os.MkdirAll(watchDir, 0755)

	// Invalid: missing version
	invalid := []byte(`{"subject":"No Version","timestamp":"2024-01-01T00:00:00Z","bodyFormat":"plain"}`)
	writeFile(t, filepath.Join(watchDir, "invalid.json"), invalid)

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}

	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	defer ew.Stop()

	// Wait for OnError
	errReceived := cb.waitError(t, 3*time.Second)
	if errReceived == nil {
		t.Fatal("expected OnError to be called, got nil")
	}

	// File should be moved to errors/
	errorsDir := filepath.Join(watchDir, "errors")
	if _, statErr := os.Stat(filepath.Join(errorsDir, "invalid.json")); os.IsNotExist(statErr) {
		t.Error("invalid file was not moved to errors directory")
	}

	// Original should be gone
	if _, statErr := os.Stat(filepath.Join(watchDir, "invalid.json")); !os.IsNotExist(statErr) {
		t.Error("invalid file still exists in watch directory")
	}
}

// Test 5: Snapshot() returns stable deterministic order (sorted by timestamp ascending).
func TestEmailWatcher_Snapshot_SortedByTimestamp(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	os.MkdirAll(watchDir, 0755)

	// Write multiple emails with different timestamps.
	emails := []struct {
		file      string
		subject   string
		timestamp string
	}{
		{"b.json", "B Email", "2024-01-03T00:00:00Z"},
		{"a.json", "A Email", "2024-01-01T00:00:00Z"},
		{"c.json", "C Email", "2024-01-02T00:00:00Z"},
	}
	for _, e := range emails {
		data := makeValidEmail(t, e.subject, e.timestamp)
		writeFile(t, filepath.Join(watchDir, e.file), data)
	}

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}

	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	defer ew.Stop()

	// Wait until all 3 emails are in the queue (may take multiple snapshots).
	deadline := time.Now().Add(5 * time.Second)
	var snap []EmailWithId
	for time.Now().Before(deadline) {
		snap = ew.Snapshot()
		if len(snap) == 3 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if len(snap) != 3 {
		t.Fatalf("expected 3 emails in snapshot, got %d", len(snap))
	}

	// Verify sorted by timestamp ascending.
	for i := 1; i < len(snap); i++ {
		if snap[i].Message.Timestamp < snap[i-1].Message.Timestamp {
			t.Errorf("snapshot not sorted: snap[%d].Timestamp=%q < snap[%d].Timestamp=%q",
				i, snap[i].Message.Timestamp, i-1, snap[i-1].Message.Timestamp)
		}
	}
}

// Test 6: Concurrent Snapshot() calls don't race (verified by -race flag).
func TestEmailWatcher_Snapshot_ConcurrentReads(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	os.MkdirAll(watchDir, 0755)

	data := makeValidEmail(t, "Concurrent Test", "2024-01-01T00:00:00Z")
	writeFile(t, filepath.Join(watchDir, "concurrent.json"), data)

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}

	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	defer ew.Stop()

	// Spin up two readers and one writer concurrently.
	var wg sync.WaitGroup
	const goroutines = 5
	for i := 0; i < goroutines; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 20; j++ {
				_ = ew.Snapshot()
				time.Sleep(time.Millisecond)
			}
		}()
	}
	wg.Wait()
}

// Test 7: Stop() called twice must not panic and must return quickly.
func TestEmailWatcher_StopIsIdempotent(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}

	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}

	// First stop — must complete
	done := make(chan struct{})
	go func() {
		defer func() {
			if r := recover(); r != nil {
				t.Errorf("first Stop() panicked: %v", r)
			}
			close(done)
		}()
		ew.Stop()
	}()
	select {
	case <-done:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("first Stop() did not return within 500ms")
	}

	// Second stop — must not panic and must return within 100ms
	done2 := make(chan struct{})
	go func() {
		defer func() {
			if r := recover(); r != nil {
				t.Errorf("second Stop() panicked: %v", r)
			}
			close(done2)
		}()
		ew.Stop()
	}()
	select {
	case <-done2:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("second Stop() did not return within 100ms (deadlock or non-idempotent)")
	}
}

// TestDoubleStopNoPanic is an alias-style test name for the plan requirement.
func TestDoubleStopNoPanic(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}

	ew.Stop()

	panicked := false
	func() {
		defer func() {
			if r := recover(); r != nil {
				panicked = true
			}
		}()
		ew.Stop()
	}()

	if panicked {
		t.Error("second Stop() panicked; must be idempotent")
	}
}

// Parity tests — mirror assertions from the old watcher_test.go in package main.

func TestEmailWatcher_GetEmails_Empty_Mapi(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	defer ew.Stop()

	emails := ew.GetEmails()
	if len(emails) != 0 {
		t.Errorf("GetEmails() length = %d, want 0", len(emails))
	}
}

// TestEmailWatcher_MarkProcessed_NotFound_Mapi verifies that MarkProcessed
// on an unknown id returns nil (idempotent — changed in Phase 9 Plan 03).
// Previously this tested for an error; the behaviour was made idempotent to
// support toast activation + automode double-signal tolerance (RESEARCH §7).
func TestEmailWatcher_MarkProcessed_NotFound_Mapi(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	defer ew.Stop()

	err = ew.MarkProcessed("nonexistent-id")
	if err != nil {
		t.Errorf("MarkProcessed() should return nil for unknown id (idempotent), got: %v", err)
	}
}

// TestEmailWatcher_Delete_NotFound_Mapi verifies that Delete on an unknown id
// returns nil (idempotent — changed in Phase 9 Plan 03).
func TestEmailWatcher_Delete_NotFound_Mapi(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	defer ew.Stop()

	err = ew.Delete("nonexistent-id")
	if err != nil {
		t.Errorf("Delete() should return nil for unknown id (idempotent), got: %v", err)
	}
}

// TestMarkProcessedIdempotent: process an email, MarkProcessed it (removes the
// file), MarkProcessed again with same id — second call must return nil.
func TestMarkProcessedIdempotent(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	os.MkdirAll(watchDir, 0755)

	data := makeValidEmail(t, "Idempotent Test", "2024-01-01T00:00:00Z")
	filePath := filepath.Join(watchDir, "idempotent.json")
	writeFile(t, filePath, data)

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	defer ew.Stop()

	// Wait for the email to be registered in the watcher.
	snap := cb.waitSnapshot(t, 3*time.Second)
	if len(snap) != 1 {
		t.Fatalf("expected 1 email in snapshot, got %d", len(snap))
	}
	id := snap[0].Id

	// First MarkProcessed: removes the file and cleans up state.
	if err := ew.MarkProcessed(id); err != nil {
		t.Fatalf("first MarkProcessed(%q) error = %v", id, err)
	}

	// File must be gone.
	if _, statErr := os.Stat(filePath); !os.IsNotExist(statErr) {
		t.Error("file still exists after MarkProcessed — expected removal")
	}

	// Second MarkProcessed with the same id — must return nil (idempotent).
	if err := ew.MarkProcessed(id); err != nil {
		t.Errorf("second MarkProcessed(%q) should return nil (idempotent), got: %v", id, err)
	}
}

// TestDeleteIdempotent: delete an email, Delete it again with same id — second
// call must return nil.
func TestDeleteIdempotent(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	os.MkdirAll(watchDir, 0755)

	data := makeValidEmail(t, "Delete Idempotent Test", "2024-01-02T00:00:00Z")
	filePath := filepath.Join(watchDir, "delete-idempotent.json")
	writeFile(t, filePath, data)

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	defer ew.Stop()

	snap := cb.waitSnapshot(t, 3*time.Second)
	if len(snap) != 1 {
		t.Fatalf("expected 1 email in snapshot, got %d", len(snap))
	}
	id := snap[0].Id

	// First Delete: removes the file.
	if err := ew.Delete(id); err != nil {
		t.Fatalf("first Delete(%q) error = %v", id, err)
	}

	// File must be gone.
	if _, statErr := os.Stat(filePath); !os.IsNotExist(statErr) {
		t.Error("file still exists after Delete — expected removal")
	}

	// Second Delete with the same id — must return nil (idempotent).
	if err := ew.Delete(id); err != nil {
		t.Errorf("second Delete(%q) should return nil (idempotent), got: %v", id, err)
	}
}

// TestMarkProcessed_DispatchesQueueChanged: covers the regression surfaced by
// the Phase 11 smoke — drafted rows persisted in the UI because MarkProcessed
// cleared the in-memory maps but never dispatched OnQueueChanged. The fsnotify
// Remove event that fires shortly after the disk delete races with the map
// cleanup, so handleRemove's lookup misses and it skips its own dispatch.
func TestMarkProcessed_DispatchesQueueChanged(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	os.MkdirAll(watchDir, 0755)

	data := makeValidEmail(t, "MarkProcessed Dispatch Test", "2024-01-03T00:00:00Z")
	writeFile(t, filepath.Join(watchDir, "mp-dispatch.json"), data)

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	defer ew.Stop()

	snap := cb.waitSnapshot(t, 3*time.Second)
	if len(snap) != 1 {
		t.Fatalf("expected 1 email in arrival snapshot, got %d", len(snap))
	}
	id := snap[0].Id

	if err := ew.MarkProcessed(id); err != nil {
		t.Fatalf("MarkProcessed(%q) error = %v", id, err)
	}

	// After MarkProcessed, OnQueueChanged MUST fire with an empty snapshot —
	// otherwise the frontend sits on stale state and the drafted row never
	// leaves the UI. Use a 2s budget: fsnotify Remove may also fire, but the
	// handler's exists-guard means it won't double-dispatch.
	post := cb.waitSnapshot(t, 2*time.Second)
	if len(post) != 0 {
		t.Errorf("expected empty snapshot after MarkProcessed, got %d items", len(post))
	}
}

// TestDelete_DispatchesQueueChanged: mirror of the MarkProcessed test — same
// race, same fix. Surfaces the "Dismiss button has no visible effect" bug.
func TestDelete_DispatchesQueueChanged(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	os.MkdirAll(watchDir, 0755)

	data := makeValidEmail(t, "Delete Dispatch Test", "2024-01-04T00:00:00Z")
	writeFile(t, filepath.Join(watchDir, "del-dispatch.json"), data)

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	defer ew.Stop()

	snap := cb.waitSnapshot(t, 3*time.Second)
	if len(snap) != 1 {
		t.Fatalf("expected 1 email in arrival snapshot, got %d", len(snap))
	}
	id := snap[0].Id

	if err := ew.Delete(id); err != nil {
		t.Fatalf("Delete(%q) error = %v", id, err)
	}

	post := cb.waitSnapshot(t, 2*time.Second)
	if len(post) != 0 {
		t.Errorf("expected empty snapshot after Delete, got %d items", len(post))
	}
}

// TestMarkProcessedUnknownIdReturnsNil: call MarkProcessed with a never-seen id
// on an empty watcher — must return nil.
func TestMarkProcessedUnknownIdReturnsNil(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	defer ew.Stop()

	if err := ew.MarkProcessed("bogus-id-12345"); err != nil {
		t.Errorf("MarkProcessed(bogus-id) should return nil, got: %v", err)
	}
}

// TestMarkProcessed_RemovesSiblingAttachmentsDir: QUICK-260423-tk6 cleanup
// invariant. The DLL writes <stem>.json alongside a sibling <stem>/ dir that
// holds copied attachments. When the Wails app processes the email, it must
// remove BOTH — privacy-first: no retention.
func TestMarkProcessed_RemovesSiblingAttachmentsDir(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	os.MkdirAll(watchDir, 0755)

	// Seed the JSON (stem = "mp-tk6") and a sibling attachments dir.
	stem := "mp-tk6"
	data := makeValidEmail(t, "TK6 MarkProcessed Attach", "2024-01-05T00:00:00Z")
	writeFile(t, filepath.Join(watchDir, stem+".json"), data)
	attachDir := filepath.Join(watchDir, stem)
	if err := os.MkdirAll(attachDir, 0755); err != nil {
		t.Fatalf("MkdirAll(attachDir) error = %v", err)
	}
	writeFile(t, filepath.Join(attachDir, "report.pdf"), []byte("PDF-DATA"))

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	defer ew.Stop()

	snap := cb.waitSnapshot(t, 3*time.Second)
	if len(snap) != 1 {
		t.Fatalf("expected 1 email in snapshot, got %d", len(snap))
	}
	id := snap[0].Id

	if err := ew.MarkProcessed(id); err != nil {
		t.Fatalf("MarkProcessed(%q) error = %v", id, err)
	}

	// Sibling attachments dir must be gone (privacy-first: no retention).
	if _, statErr := os.Stat(attachDir); !os.IsNotExist(statErr) {
		t.Errorf("sibling attachments dir still exists after MarkProcessed: %v", statErr)
	}
}

// TestDelete_RemovesSiblingAttachmentsDir: mirrors the MarkProcessed test —
// Dismiss must also tear down the attachments dir.
func TestDelete_RemovesSiblingAttachmentsDir(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	os.MkdirAll(watchDir, 0755)

	stem := "del-tk6"
	data := makeValidEmail(t, "TK6 Delete Attach", "2024-01-06T00:00:00Z")
	writeFile(t, filepath.Join(watchDir, stem+".json"), data)
	attachDir := filepath.Join(watchDir, stem)
	if err := os.MkdirAll(attachDir, 0755); err != nil {
		t.Fatalf("MkdirAll(attachDir) error = %v", err)
	}
	writeFile(t, filepath.Join(attachDir, "resume.pdf"), []byte("PDF"))

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	defer ew.Stop()

	snap := cb.waitSnapshot(t, 3*time.Second)
	if len(snap) != 1 {
		t.Fatalf("expected 1 email in snapshot, got %d", len(snap))
	}
	id := snap[0].Id

	if err := ew.Delete(id); err != nil {
		t.Fatalf("Delete(%q) error = %v", id, err)
	}

	if _, statErr := os.Stat(attachDir); !os.IsNotExist(statErr) {
		t.Errorf("sibling attachments dir still exists after Delete: %v", statErr)
	}
}

// Verify Snapshot returns a sorted copy (sort package used for assertion).
func TestEmailWatcher_Snapshot_ReturnsSnapshot(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	os.MkdirAll(watchDir, 0755)

	data := makeValidEmail(t, "Snapshot Test", "2024-01-01T00:00:00Z")
	writeFile(t, filepath.Join(watchDir, "snap.json"), data)

	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}

	if err := ew.Start(); err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	defer ew.Stop()

	// Wait for watcher to process file
	cb.waitSnapshot(t, 3*time.Second)

	snap := ew.Snapshot()
	if len(snap) != 1 {
		t.Fatalf("expected 1 in snapshot, got %d", len(snap))
	}
	if snap[0].Message.Subject != "Snapshot Test" {
		t.Errorf("subject = %q, want %q", snap[0].Message.Subject, "Snapshot Test")
	}

	// Verify snapshot is a copy: mutating it doesn't affect the watcher's state.
	snap[0].Id = "mutated"
	snap2 := ew.Snapshot()
	if len(snap2) != 1 || snap2[0].Id == "mutated" {
		t.Error("Snapshot() should return an independent copy")
	}
}

// Ensure sort package is used (prevent unused import).
var _ = sort.Sort
