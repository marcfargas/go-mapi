package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
	mapi "github.com/marcfargas/go-mapi/native-host/internal/mapi"
)

// EmailWatcher watches for new email JSON files
type EmailWatcher struct {
	watchDir     string
	processedDir string
	errorsDir    string
	watcher      *fsnotify.Watcher
	messaging    *NativeMessaging
	emails       map[string]*mapi.MailMessage // id -> email
	fileToID     map[string]string            // filename -> id
	mu           sync.RWMutex
	done         chan struct{}
}

// NewEmailWatcher creates a new email watcher
func NewEmailWatcher(watchDir string, messaging *NativeMessaging) (*EmailWatcher, error) {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, fmt.Errorf("failed to create watcher: %w", err)
	}

	processedDir := filepath.Join(watchDir, "processed")
	errorsDir := filepath.Join(watchDir, "errors")

	// Create directories if they don't exist
	for _, dir := range []string{watchDir, processedDir, errorsDir} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			watcher.Close()
			return nil, fmt.Errorf("failed to create directory %s: %w", dir, err)
		}
	}

	return &EmailWatcher{
		watchDir:     watchDir,
		processedDir: processedDir,
		errorsDir:    errorsDir,
		watcher:      watcher,
		messaging:    messaging,
		emails:       make(map[string]*mapi.MailMessage),
		fileToID:     make(map[string]string),
		done:         make(chan struct{}),
	}, nil
}

// Start begins watching for files
func (ew *EmailWatcher) Start() error {
	// Add watch directory
	if err := ew.watcher.Add(ew.watchDir); err != nil {
		return fmt.Errorf("failed to watch directory: %w", err)
	}

	// Process existing files first
	if err := ew.processExistingFiles(); err != nil {
		logError("failed to process existing files: %v", err)
	}

	// Start watching for new files
	go ew.watchLoop()

	return nil
}

// Stop stops the watcher
func (ew *EmailWatcher) Stop() {
	close(ew.done)
	ew.watcher.Close()
}

// GetEmails returns all current emails
func (ew *EmailWatcher) GetEmails() map[string]*mapi.MailMessage {
	ew.mu.RLock()
	defer ew.mu.RUnlock()

	// Return a copy
	result := make(map[string]*mapi.MailMessage, len(ew.emails))
	for k, v := range ew.emails {
		result[k] = v
	}
	return result
}

// MarkProcessed deletes a processed email file (privacy-first: no retention)
func (ew *EmailWatcher) MarkProcessed(id string) error {
	ew.mu.Lock()
	defer ew.mu.Unlock()

	// Find file by ID
	var filename string
	for f, fid := range ew.fileToID {
		if fid == id {
			filename = f
			break
		}
	}

	if filename == "" {
		return fmt.Errorf("email not found: %s", id)
	}

	srcPath := filepath.Join(ew.watchDir, filename)

	if err := os.Remove(srcPath); err != nil {
		return fmt.Errorf("failed to delete file: %w", err)
	}

	delete(ew.emails, id)
	delete(ew.fileToID, filename)

	return nil
}

// Delete removes an email file
func (ew *EmailWatcher) Delete(id string) error {
	ew.mu.Lock()
	defer ew.mu.Unlock()

	// Find file by ID
	var filename string
	for f, fid := range ew.fileToID {
		if fid == id {
			filename = f
			break
		}
	}

	if filename == "" {
		return fmt.Errorf("email not found: %s", id)
	}

	srcPath := filepath.Join(ew.watchDir, filename)

	if err := os.Remove(srcPath); err != nil {
		return fmt.Errorf("failed to delete file: %w", err)
	}

	delete(ew.emails, id)
	delete(ew.fileToID, filename)

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
			logError("watcher error: %v", err)

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
		logInfo("retry %d reading %s: %v", attempt, filename, err)
		time.Sleep(200 * time.Millisecond)
	}
	if err != nil {
		logError("failed to read file %s after retries: %v", filename, err)
		ew.moveToErrors(filename, fmt.Sprintf("read error: %v", err))
		return
	}

	// Parse JSON
	var mail mapi.MailMessage
	if err := json.Unmarshal(data, &mail); err != nil {
		logError("failed to parse file %s: %v", filename, err)
		ew.moveToErrors(filename, fmt.Sprintf("parse error: %v", err))
		return
	}

	// Normalize recipient addresses (strip MAPI prefixes like SMTP:, mailto:)
	normalizeRecipients(mail.Recipients.To)
	normalizeRecipients(mail.Recipients.CC)
	normalizeRecipients(mail.Recipients.BCC)

	// Validate required fields
	if err := mapi.ValidateMailMessage(&mail); err != nil {
		logError("invalid email in %s: %v", filename, err)
		ew.moveToErrors(filename, fmt.Sprintf("validation error: %v", err))
		return
	}

	// Generate unique ID from content
	id := generateID(data, filename)

	// Stamp host version on the local mail before publishing the pointer into
	// the map. FOUND-01: if we stamp after the unlock, concurrent readers
	// holding the RLock via GetEmails receive the same *MailMessage and race
	// with this write. Mutate before publish to keep the fix surgical.
	mail.HostVersion = Version

	// Store email
	ew.mu.Lock()
	ew.emails[id] = &mail
	ew.fileToID[filename] = id
	ew.mu.Unlock()

	// Notify extension
	if err := ew.messaging.SendEmail(id, &mail); err != nil {
		logError("failed to send email to extension: %v", err)
	}

	logInfo("processed email: %s (id: %s)", filename, id[:8])
}

func (ew *EmailWatcher) handleRemove(filename string) {
	ew.mu.Lock()
	id, exists := ew.fileToID[filename]
	if exists {
		delete(ew.emails, id)
		delete(ew.fileToID, filename)
	}
	ew.mu.Unlock()

	if exists {
		if err := ew.messaging.SendRemoved(id); err != nil {
			logError("failed to send removed notification: %v", err)
		}
	}
}

func (ew *EmailWatcher) moveToErrors(filename, reason string) {
	src := filepath.Join(ew.watchDir, filename)
	dst := filepath.Join(ew.errorsDir, filename)

	if err := os.Rename(src, dst); err != nil {
		logError("failed to move %s to errors: %v", filename, err)
		return
	}

	// Write error log
	logFile := dst + ".error"
	os.WriteFile(logFile, []byte(reason), 0644)
}

// normalizeAddress strips common MAPI address prefixes (SMTP:, mailto:).
// Kept in package main temporarily; moves into internal/mapi with watcher in Task 3.
func normalizeAddress(addr string) string {
	prefixes := []string{"SMTP:", "smtp:", "MAILTO:", "mailto:"}
	for _, prefix := range prefixes {
		if strings.HasPrefix(addr, prefix) {
			return strings.TrimPrefix(addr, prefix)
		}
	}
	return addr
}

// normalizeRecipients applies address normalization to a slice of recipients.
// Kept in package main temporarily; moves into internal/mapi with watcher in Task 3.
func normalizeRecipients(recipients []mapi.Recipient) {
	for i := range recipients {
		recipients[i].Address = normalizeAddress(recipients[i].Address)
	}
}

func generateID(data []byte, filename string) string {
	hash := sha256.New()
	hash.Write(data)
	hash.Write([]byte(filename))
	return hex.EncodeToString(hash.Sum(nil))
}
