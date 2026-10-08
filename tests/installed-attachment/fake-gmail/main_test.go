package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/textproto"
	"os"
	"path/filepath"
	"testing"
)

var testFiles = map[string][]byte{
	"report.txt": []byte("exact attachment\r\nwith bytes\x00"),
	"image.bin":  {0, 1, 2, 253, 254, 255},
}

func testOracle(t *testing.T) *oracle {
	t.Helper()
	want := expected{RunID: "run-1", Subject: "Ticket569 installed Windows seam", Recipient: "test@example.invalid", Attachments: map[string]string{}}
	for name, data := range testFiles {
		want.Attachments[name] = hashBytes(data)
	}
	return newOracle(t.TempDir(), want)
}

func hashBytes(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

func rawDraft(t *testing.T, names ...string) []byte {
	t.Helper()
	var raw bytes.Buffer
	w := multipart.NewWriter(&raw)
	for _, name := range names {
		part, err := w.CreatePart(textproto.MIMEHeader{
			"Content-Disposition":       []string{fmt.Sprintf(`attachment; filename=%q`, name)},
			"Content-Transfer-Encoding": []string{"base64"},
			"Content-Type":              []string{"application/octet-stream"},
		})
		if err != nil {
			t.Fatal(err)
		}
		_, _ = part.Write([]byte(base64.StdEncoding.EncodeToString(testFiles[name])))
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	var envelope bytes.Buffer
	_, _ = fmt.Fprintf(&envelope, "To: Synthetic <test@example.invalid>\r\nSubject: Ticket569 installed Windows seam\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=%q\r\n\r\n", w.Boundary())
	envelope.Write(raw.Bytes())
	encoded := base64.RawURLEncoding.EncodeToString(envelope.Bytes())
	data, _ := json.Marshal(map[string]any{"message": map[string]string{"raw": encoded}})
	return data
}

func TestDraftOracleRequiresExactAttachmentMultisetAndBytes(t *testing.T) {
	for _, tc := range []struct {
		name  string
		files []string
		valid bool
	}{
		{name: "both exact", files: []string{"report.txt", "image.bin"}, valid: true},
		{name: "missing", files: []string{"report.txt"}},
		{name: "duplicate", files: []string{"report.txt", "report.txt", "image.bin"}},
		{name: "unexpected", files: []string{"report.txt", "image.bin", "other.bin"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			o := testOracle(t)
			entry, err := o.checkDraft(bytes.NewReader(rawDraft(t, tc.files...)))
			if tc.valid && err != nil {
				t.Fatal(err)
			}
			if !tc.valid && err == nil {
				t.Fatal("invalid attachment set was accepted")
			}
			if tc.valid && (len(entry.Attachments) != 2 || entry.Attachments[0].SHA256 == "") {
				t.Fatalf("unexpected accepted evidence: %#v", entry)
			}
		})
	}
	t.Run("byte corrupted", func(t *testing.T) {
		o := testOracle(t)
		o.expected.Attachments["report.txt"] = hashBytes([]byte("different bytes"))
		if _, err := o.checkDraft(bytes.NewReader(rawDraft(t, "report.txt", "image.bin"))); err == nil {
			t.Fatal("corrupted attachment bytes were accepted")
		}
	})
	t.Run("wrong envelope", func(t *testing.T) {
		o := testOracle(t)
		o.expected.Subject = "different subject"
		if _, err := o.checkDraft(bytes.NewReader(rawDraft(t, "report.txt", "image.bin"))); err == nil {
			t.Fatal("unexpected draft envelope was accepted")
		}
	})
}

func TestOracleLatchesUnexpectedRequestAndLateDuplicate(t *testing.T) {
	t.Run("rejection", func(t *testing.T) {
		o := testOracle(t)
		o.rejectRequest(fmt.Errorf("unexpected route"))
		if !o.current().Failed || o.current().Rejected != 1 {
			t.Fatalf("rejection was not irreversible: %#v", o.current())
		}
	})
	t.Run("late duplicate", func(t *testing.T) {
		o := testOracle(t)
		entry, err := o.checkDraft(bytes.NewReader(rawDraft(t, "report.txt", "image.bin")))
		if err != nil {
			t.Fatal(err)
		}
		o.attemptDraft()
		o.acceptDraft(entry)
		o.attemptDraft()
		o.acceptDraft(entry)
		state := o.current()
		if !state.Failed || state.DraftAttempts != 2 || state.AcceptedDraft != 1 {
			t.Fatalf("late duplicate did not fail closed: %#v", state)
		}
	})
}

func TestSnapshotWriteFailureLatchesAndFailsClosed(t *testing.T) {
	o := testOracle(t)
	path := filepath.Join(t.TempDir(), "directory")
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := o.writeAtomic(path, map[string]string{"value": "cannot replace directory"}); err == nil {
		t.Fatal("snapshot write unexpectedly succeeded")
	}
	if !o.current().Failed {
		t.Fatal("snapshot write failure did not latch")
	}
}

func TestFinalSnapshotRejectsMissingTruncatedAndWrongRun(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "final.json")
	if _, err := readFinalSnapshot(path, "run-1"); err == nil {
		t.Fatal("missing snapshot passed")
	}
	if err := os.WriteFile(path, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readFinalSnapshot(path, "run-1"); err == nil {
		t.Fatal("truncated snapshot passed")
	}
	if err := os.WriteFile(path, []byte(`{"schemaVersion":1,"runId":"wrong","final":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readFinalSnapshot(path, "run-1"); err == nil {
		t.Fatal("wrong-run snapshot passed")
	}
}
