package mapi

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// attachmentOutcome processes one descriptor named message.json in watchDir
// that references paths, and reports whether the watcher accepted it. On
// rejection it returns the reported error and checks that the descriptor was
// moved to the errors folder.
func attachmentOutcome(t *testing.T, watchDir string, paths ...string) (bool, error) {
	t.Helper()
	cb := newStubCallback()
	ew, err := NewEmailWatcher(watchDir, cb)
	if err != nil {
		t.Fatalf("NewEmailWatcher: %v", err)
	}
	defer ew.Stop()

	msg := MailMessage{
		Version:    1,
		Timestamp:  "2026-09-30T00:00:00Z",
		BodyFormat: "plain",
		Recipients: Recipients{To: []Recipient{{Address: "test@example.com"}}},
	}
	for _, path := range paths {
		msg.Attachments = append(msg.Attachments, Attachment{Filename: filepath.Base(path), Path: path})
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	writeFile(t, filepath.Join(watchDir, "message.json"), data)

	ew.processFile("message.json")
	select {
	case snapshot := <-cb.queue:
		if len(snapshot) != 1 || len(snapshot[0].Message.Attachments) != len(paths) {
			t.Fatalf("unexpected accepted snapshot: %#v", snapshot)
		}
		return true, nil
	case err := <-cb.errors:
		if _, statErr := os.Stat(filepath.Join(watchDir, "errors", "message.json")); statErr != nil {
			t.Fatalf("rejected descriptor was not moved to errors: %v", statErr)
		}
		return false, err
	case <-time.After(time.Second):
		t.Fatal("watcher neither accepted nor rejected the descriptor")
		return false, nil
	}
}

// stageAttachment creates <watchDir>/message/<name> and returns its path.
func stageAttachment(t *testing.T, watchDir, name string) string {
	t.Helper()
	dir := filepath.Join(watchDir, "message")
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	path := filepath.Join(dir, name)
	writeFile(t, path, []byte("attachment "+name))
	return path
}

// A user profile folder that is a link to another location (a volume mount
// point or junction on Windows, a symbolic link elsewhere) resolves in the
// same way for the attachment folder and for its files, so it is accepted.
func TestEmailWatcher_AcceptsAttachmentBelowLinkedProfile(t *testing.T) {
	tmpDir := t.TempDir()
	realProfile := filepath.Join(tmpDir, "profile-disk")
	if err := os.MkdirAll(realProfile, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	profile := filepath.Join(tmpDir, "profile")
	if err := os.Symlink(realProfile, profile); err != nil {
		t.Skipf("symlink creation unavailable on this test host: %v", err)
	}
	watchDir := filepath.Join(profile, "AppData", "Local", "go-mapi", "queue")
	if err := os.MkdirAll(watchDir, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}

	accepted, err := attachmentOutcome(t, watchDir, stageAttachment(t, watchDir, "report.pdf"))
	if !accepted {
		t.Fatalf("attachment below a linked profile was rejected: %v", err)
	}
}

func TestEmailWatcher_RejectsAttachmentDotDotEscape(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	stageAttachment(t, watchDir, "inside.txt")
	writeFile(t, filepath.Join(tmpDir, "outside.txt"), []byte("secret"))

	escape := filepath.Join(watchDir, "message") + string(filepath.Separator) +
		filepath.Join("..", "..", "outside.txt")
	accepted, err := attachmentOutcome(t, watchDir, escape)
	if accepted || err == nil {
		t.Fatal("'..' escape out of the attachment folder was accepted")
	}
}

func TestEmailWatcher_RejectsAttachmentThroughEscapingFileSymlink(t *testing.T) {
	tmpDir := t.TempDir()
	watchDir := filepath.Join(tmpDir, "watch")
	stageAttachment(t, watchDir, "inside.txt")
	outsideFile := filepath.Join(tmpDir, "secret.txt")
	writeFile(t, outsideFile, []byte("secret"))
	link := filepath.Join(watchDir, "message", "secret.txt")
	if err := os.Symlink(outsideFile, link); err != nil {
		t.Skipf("symlink creation unavailable on this test host: %v", err)
	}

	accepted, err := attachmentOutcome(t, watchDir, link)
	if accepted || err == nil {
		t.Fatal("file symlink escaping the attachment folder was accepted")
	}
}

func TestEmailWatcher_RejectsAttachmentFolderItself(t *testing.T) {
	watchDir := filepath.Join(t.TempDir(), "watch")
	stageAttachment(t, watchDir, "inside.txt")

	accepted, err := attachmentOutcome(t, watchDir, filepath.Join(watchDir, "message"))
	if accepted || err == nil {
		t.Fatal("the attachment folder itself was accepted as an attachment")
	}
}

func TestEmailWatcher_RejectsAttachmentOfAnotherDescriptor(t *testing.T) {
	watchDir := filepath.Join(t.TempDir(), "watch")
	other := filepath.Join(watchDir, "other")
	if err := os.MkdirAll(other, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	foreign := filepath.Join(other, "foreign.txt")
	writeFile(t, foreign, []byte("foreign"))

	accepted, err := attachmentOutcome(t, watchDir, foreign)
	if accepted || err == nil {
		t.Fatal("attachment of another descriptor was accepted")
	}
}

func TestPathInsideDir(t *testing.T) {
	sep := string(filepath.Separator)
	dir := filepath.Join(sep+"base", "queue", "message")
	cases := []struct {
		path string
		want bool
	}{
		{filepath.Join(dir, "a.txt"), true},
		{filepath.Join(dir, "sub", "a.txt"), true},
		{dir, false},
		{filepath.Dir(dir), false},
		{filepath.Join(filepath.Dir(dir), "message2", "a.txt"), false},
		{filepath.Join(filepath.Dir(dir), "messagex"), false},
		{filepath.Join(sep+"elsewhere", "a.txt"), false},
	}
	for _, c := range cases {
		if got := pathInsideDir(dir, c.path); got != c.want {
			t.Errorf("pathInsideDir(%q, %q) = %v, want %v", dir, c.path, got, c.want)
		}
	}
}
