package mapi

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

// EmailWithId pairs the watcher's content-hash ID with the parsed message.
type EmailWithId struct {
	Id      string       `json:"id"`
	Message *MailMessage `json:"message"`
}

// WatcherCallback is invoked on queue state changes. Implementations must be
// race-safe (watcher dispatches from its own goroutine).
type WatcherCallback interface {
	OnQueueChanged(snapshot []EmailWithId)
	OnError(err error)
}

// EmailWatcher watches for new email JSON files, validates them, and notifies
// a WatcherCallback on queue changes.
type EmailWatcher struct {
	watchDir     string
	processedDir string
	errorsDir    string
	watcher      *fsnotify.Watcher
	cb           WatcherCallback
	emails       map[string]*MailMessage // id -> email
	fileToID     map[string]string       // filename -> id
	mu           sync.RWMutex
	done         chan struct{}
	stopOnce     sync.Once
}

// NewEmailWatcher creates a new email watcher. If cb is nil, queue changes are
// silently discarded (a warning is the caller's responsibility).
func NewEmailWatcher(watchDir string, cb WatcherCallback) (*EmailWatcher, error) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, fmt.Errorf("failed to create watcher: %w", err)
	}

	processedDir := filepath.Join(watchDir, "processed")
	errorsDir := filepath.Join(watchDir, "errors")

	// Create directories if they don't exist
	for _, dir := range []string{watchDir, processedDir, errorsDir} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			w.Close()
			return nil, fmt.Errorf("failed to create directory %s: %w", dir, err)
		}
	}

	return &EmailWatcher{
		watchDir:     watchDir,
		processedDir: processedDir,
		errorsDir:    errorsDir,
		watcher:      w,
		cb:           cb,
		emails:       make(map[string]*MailMessage),
		fileToID:     make(map[string]string),
		done:         make(chan struct{}),
	}, nil
}

// Start begins watching for files. Processes existing files first, then
// launches the watchLoop goroutine.
func (ew *EmailWatcher) Start() error {
	if err := ew.watcher.Add(ew.watchDir); err != nil {
		return fmt.Errorf("failed to watch directory: %w", err)
	}

	if err := ew.processExistingFiles(); err != nil {
		// Non-fatal: log via logInfo is not available here (no logging in internal/)
		_ = err
	}

	go ew.watchLoop()
	return nil
}

// Stop stops the watcher. Idempotent: subsequent calls are no-ops.
func (ew *EmailWatcher) Stop() {
	ew.stopOnce.Do(func() {
		close(ew.done)
		ew.watcher.Close()
	})
}

// Snapshot returns a stable, sorted (by timestamp ascending) copy of the
// current email queue. The returned slice is an independent copy.
func (ew *EmailWatcher) Snapshot() []EmailWithId {
	ew.mu.RLock()
	defer ew.mu.RUnlock()
	return ew.snapshotLocked()
}

// snapshotLocked builds the sorted EmailWithId slice. Caller must hold at
// least a read lock on ew.mu.
func (ew *EmailWatcher) snapshotLocked() []EmailWithId {
	snap := make([]EmailWithId, 0, len(ew.emails))
	for id, msg := range ew.emails {
		// Copy the message to keep the snapshot independent.
		msgCopy := *msg
		snap = append(snap, EmailWithId{Id: id, Message: &msgCopy})
	}
	sort.Slice(snap, func(i, j int) bool {
		return snap[i].Message.Timestamp < snap[j].Message.Timestamp
	})
	return snap
}

// GetEmails returns all current emails as a map copy.
// Deprecated: use Snapshot() in new code.
func (ew *EmailWatcher) GetEmails() map[string]*MailMessage {
	ew.mu.RLock()
	defer ew.mu.RUnlock()

	result := make(map[string]*MailMessage, len(ew.emails))
	for k, v := range ew.emails {
		result[k] = v
	}
	return result
}

// MarkProcessed deletes the email's JSON file from watchDir. Idempotent:
// calling with an unknown id (already-processed, never-existed, or raced with
// a concurrent Delete) returns nil. Caller does not need to pre-check.
//
// Privacy-first: no retention — the file is removed immediately on success.
// Phase 9 NOTIF-03 toast activation + automode double-signal tolerance
// depend on this; see 09-RESEARCH.md §7 for the full rationale.
func (ew *EmailWatcher) MarkProcessed(id string) error {
	ew.mu.Lock()

	var filename string
	for f, fid := range ew.fileToID {
		if fid == id {
			filename = f
			break
		}
	}
	if filename == "" {
		// Idempotent: unknown id → already-processed (or never-existed) → success.
		// Phase 9 NOTIF-03 toast activation + automode double-signal tolerance
		// depend on this; see 09-RESEARCH.md §7 for the full rationale.
		ew.mu.Unlock()
		return nil
	}

	srcPath := filepath.Join(ew.watchDir, filename)
	if err := os.Remove(srcPath); err != nil {
		ew.mu.Unlock()
		return fmt.Errorf("failed to delete file: %w", err)
	}

	delete(ew.emails, id)
	delete(ew.fileToID, filename)
	snap := ew.snapshotLocked()
	ew.mu.Unlock()

	// Dispatch queue-changed ourselves. The fsnotify Remove event that will fire
	// shortly races with this cleanup — by the time handleRemove locks, the
	// filename lookup misses and its exists-guard skips dispatch. Without this
	// call the frontend never learns the row was processed (bug found in Phase
	// 11 smoke: drafted rows persisted in the UI indefinitely).
	ew.dispatchQueueChanged(snap)
	return nil
}

// Delete removes an email file from the queue without creating a draft. Idempotent:
// calling with an unknown id (already-deleted, never-existed, or raced with
// a concurrent MarkProcessed) returns nil. Caller does not need to pre-check.
//
// Privacy-first: no retention — the file is removed immediately on success.
// Phase 9 NOTIF-03 toast activation + automode double-signal tolerance
// depend on this; see 09-RESEARCH.md §7 for the full rationale.
func (ew *EmailWatcher) Delete(id string) error {
	ew.mu.Lock()

	var filename string
	for f, fid := range ew.fileToID {
		if fid == id {
			filename = f
			break
		}
	}
	if filename == "" {
		// Idempotent: unknown id → already-deleted (or never-existed) → success.
		// Phase 9 NOTIF-03 toast activation + automode double-signal tolerance
		// depend on this; see 09-RESEARCH.md §7 for the full rationale.
		ew.mu.Unlock()
		return nil
	}

	srcPath := filepath.Join(ew.watchDir, filename)
	if err := os.Remove(srcPath); err != nil {
		ew.mu.Unlock()
		return fmt.Errorf("failed to delete file: %w", err)
	}

	delete(ew.emails, id)
	delete(ew.fileToID, filename)
	snap := ew.snapshotLocked()
	ew.mu.Unlock()

	// Dispatch queue-changed ourselves. See note in MarkProcessed for the race
	// with the fsnotify Remove event — same reason, same fix (Phase 11 smoke
	// finding: Dismiss button had no visible effect in the UI).
	ew.dispatchQueueChanged(snap)
	return nil
}

func (ew *EmailWatcher) processExistingFiles() error {
	entries, err := os.ReadDir(ew.watchDir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		ew.processFile(entry.Name())
	}
	return nil
}

func (ew *EmailWatcher) watchLoop() {
	// Debounce writes - wait for file to be fully written
	pending := make(map[string]time.Time)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ew.done:
			return

		case event, ok := <-ew.watcher.Events:
			if !ok {
				return
			}

			filename := filepath.Base(event.Name)
			if !strings.HasSuffix(filename, ".json") {
				continue
			}

			switch {
			case event.Op&fsnotify.Create == fsnotify.Create:
				pending[filename] = time.Now()
			case event.Op&fsnotify.Write == fsnotify.Write:
				pending[filename] = time.Now()
			case event.Op&fsnotify.Remove == fsnotify.Remove:
				delete(pending, filename)
				ew.handleRemove(filename)
			}

		case err, ok := <-ew.watcher.Errors:
			if !ok {
				return
			}
			ew.dispatchError(fmt.Errorf("watcher error: %w", err))

		case <-ticker.C:
			// Process files that haven't been modified for 500ms
			now := time.Now()
			for filename, lastMod := range pending {
				if now.Sub(lastMod) > 500*time.Millisecond {
					delete(pending, filename)
					ew.processFile(filename)
				}
			}
		}
	}
}

func (ew *EmailWatcher) processFile(filename string) {
	fullPath := filepath.Join(ew.watchDir, filename)

	// Retry with backoff (handles AV file locking)
	var data []byte
	var err error
	for attempt := 1; attempt <= 3; attempt++ {
		data, err = os.ReadFile(fullPath)
		if err == nil {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if err != nil {
		wrappedErr := fmt.Errorf("failed to read file %s after retries: %w", filename, err)
		ew.moveToErrors(filename, fmt.Sprintf("read error: %v", err))
		ew.dispatchError(wrappedErr)
		return
	}

	// Parse JSON
	var mail MailMessage
	if err := json.Unmarshal(data, &mail); err != nil {
		parseErr := fmt.Errorf("failed to parse file %s: %w", filename, err)
		ew.moveToErrors(filename, fmt.Sprintf("parse error: %v", err))
		ew.dispatchError(parseErr)
		return
	}

	// Normalize recipient addresses (strip MAPI prefixes like SMTP:, mailto:)
	normalizeRecipients(mail.Recipients.To)
	normalizeRecipients(mail.Recipients.CC)
	normalizeRecipients(mail.Recipients.BCC)

	// Validate required fields
	if err := ValidateMailMessage(&mail); err != nil {
		validErr := fmt.Errorf("invalid email in %s: %w", filename, err)
		ew.moveToErrors(filename, fmt.Sprintf("validation error: %v", err))
		ew.dispatchError(validErr)
		return
	}

	// Generate unique ID from content
	id := generateID(data, filename)

	// Store email — mutate HostVersion before publish to avoid concurrent write race.
	// See FOUND-01: stamp before taking the lock so concurrent GetEmails/Snapshot
	// readers never see an unstamped pointer.
	// (Note: Version is not available inside internal/mapi — callers stamp HostVersion
	// by wrapping the callback if needed. The watcher sets it to empty here;
	// native-host adapters may re-stamp via their callback.)

	ew.mu.Lock()
	ew.emails[id] = &mail
	ew.fileToID[filename] = id
	snap := ew.snapshotLocked()
	ew.mu.Unlock()

	ew.dispatchQueueChanged(snap)
}

func (ew *EmailWatcher) handleRemove(filename string) {
	ew.mu.Lock()
	id, exists := ew.fileToID[filename]
	if exists {
		delete(ew.emails, id)
		delete(ew.fileToID, filename)
	}
	var snap []EmailWithId
	if exists {
		snap = ew.snapshotLocked()
	}
	ew.mu.Unlock()

	if exists {
		ew.dispatchQueueChanged(snap)
	}
}

func (ew *EmailWatcher) moveToErrors(filename, reason string) {
	src := filepath.Join(ew.watchDir, filename)
	dst := filepath.Join(ew.errorsDir, filename)

	if err := os.Rename(src, dst); err != nil {
		// Best effort: if rename fails, log inline
		return
	}

	// Write error log — best-effort; ignore the error explicitly so that
	// go vet / errcheck linters stay clean if added in a future phase.
	logFile := dst + ".error"
	_ = os.WriteFile(logFile, []byte(reason), 0644)
}

func (ew *EmailWatcher) dispatchQueueChanged(snap []EmailWithId) {
	if ew.cb == nil {
		return
	}
	ew.cb.OnQueueChanged(snap)
}

func (ew *EmailWatcher) dispatchError(err error) {
	if ew.cb == nil {
		return
	}
	ew.cb.OnError(err)
}

func generateID(data []byte, filename string) string {
	hash := sha256.New()
	hash.Write(data)
	hash.Write([]byte(filename))
	return hex.EncodeToString(hash.Sum(nil))
}
