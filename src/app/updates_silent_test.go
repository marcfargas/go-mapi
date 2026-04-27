//go:build windows

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/creativeprojects/go-selfupdate"
)

// stubHTTPClient is a deterministic httpDoer that returns canned bodies for
// known URLs. Lets the silent-update full-pipeline test cover download +
// verify + swap without hitting the live GitHub Releases endpoint.
type stubHTTPClient struct {
	responses map[string][]byte
	statuses  map[string]int // optional; defaults to 200
}

func (s *stubHTTPClient) Do(req *http.Request) (*http.Response, error) {
	url := req.URL.String()
	body, ok := s.responses[url]
	if !ok {
		return &http.Response{
			StatusCode: 404,
			Body:       io.NopCloser(bytes.NewReader([]byte("not found"))),
			Header:     make(http.Header),
		}, nil
	}
	status := 200
	if s.statuses != nil {
		if st, ok := s.statuses[url]; ok {
			status = st
		}
	}
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(bytes.NewReader(body)),
		Header:     make(http.Header),
	}, nil
}

// installFullPipelineFixture sets up an installRootOverride dir + a
// programFiles32Override path with pre-existing "OLD" binaries, plus a
// stub HTTP client serving canned manifest + asset bodies. Returns the
// install root, the x86 DLL path, and the canned new contents (so tests can
// assert the swap landed). Cleanup is handled via t.Cleanup.
func installFullPipelineFixture(t *testing.T, manifestOverride []byte) (installDir, pf32Path string, want map[string][]byte) {
	t.Helper()

	installDir = filepath.Join(t.TempDir(), "installroot")
	if err := os.MkdirAll(installDir, 0o755); err != nil {
		t.Fatalf("mkdir install root: %v", err)
	}
	pf32Path = filepath.Join(t.TempDir(), "pf32", "go-mapi", "go-mapi.dll")
	if err := os.MkdirAll(filepath.Dir(pf32Path), 0o755); err != nil {
		t.Fatalf("mkdir pf32: %v", err)
	}

	// Pre-existing OLD binaries — the swap must replace them with NEW.
	for _, p := range []string{
		filepath.Join(installDir, "go-mapi.exe"),
		filepath.Join(installDir, "go-mapi.dll"),
		pf32Path,
	} {
		if err := os.WriteFile(p, []byte("OLD"), 0o644); err != nil {
			t.Fatalf("write OLD %s: %v", p, err)
		}
	}

	// Canned new asset bodies + their SHA-256 digests.
	want = map[string][]byte{
		"go-mapi.exe":     []byte("NEW-exe-content"),
		"go-mapi-x64.dll": []byte("NEW-x64-content"),
		"go-mapi-x86.dll": []byte("NEW-x86-content"),
	}
	manifestLines := make([]string, 0, len(want))
	for name, body := range want {
		sum := sha256.Sum256(body)
		manifestLines = append(manifestLines, fmt.Sprintf("%s  %s", hex.EncodeToString(sum[:]), name))
	}
	manifest := []byte(strings.Join(manifestLines, "\n") + "\n")
	if manifestOverride != nil {
		manifest = manifestOverride
	}

	base := "https://github.com/" + gitHubOwner + "/" + gitHubRepo + "/releases/latest/download/"
	stub := &stubHTTPClient{
		responses: map[string][]byte{
			base + "SHA256SUMS.txt":  manifest,
			base + "go-mapi.exe":     want["go-mapi.exe"],
			base + "go-mapi-x64.dll": want["go-mapi-x64.dll"],
			base + "go-mapi-x86.dll": want["go-mapi-x86.dll"],
		},
	}

	prevClient := silentHTTPClient
	prevRoot := installRootOverride
	prevPF32 := programFiles32Override
	prevBackoff := testBackoffOverride

	silentHTTPClient = stub
	installRootOverride = installDir
	programFiles32Override = pf32Path
	testBackoffOverride = 1 * time.Millisecond // not used on happy path, harmless

	t.Cleanup(func() {
		silentHTTPClient = prevClient
		installRootOverride = prevRoot
		programFiles32Override = prevPF32
		testBackoffOverride = prevBackoff
	})

	return installDir, pf32Path, want
}

// setupSilentLogDir redirects updatesStagingDir() to a temp dir and returns
// the log path so tests can assert log content.
func setupSilentLogDir(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	t.Setenv("GOMAPI_UPDATES_DIR", tmp)
	return filepath.Join(tmp, "update.log")
}

func TestRunSilentUpdate_NoUpdateAvailable(t *testing.T) {
	logPath := setupSilentLogDir(t)
	stub := &stubReleaseFetcher{
		release: &latestRelease{Version: "0.0.0"}, // older than Version
	}
	svc := newUpdateService("9.9.9", stub, nil)
	rc := rcWithWorkaround(runSilentUpdateWithService(context.Background(), svc))
	if rc != 0 {
		t.Fatalf("expected rc=0, got %d", rc)
	}
	body := readLogOrFail(t, logPath)
	if !strings.Contains(body, "no update available") {
		t.Errorf("log missing 'no update available': %q", body)
	}
}

// TestRunSilentUpdate_UpdateAvailable_FullPipeline replaces the
// Plan 11.1-02 stub assertion: now that the deferred-to-Plan-11.1-04 path
// is wired, this test exercises download + verify + swap end-to-end against
// a stub HTTP client serving canned manifest + asset bodies. Verifies all
// three swap targets actually receive the NEW content and the success log
// line is written without any hex digest (Pitfall 6).
func TestRunSilentUpdate_UpdateAvailable_FullPipeline(t *testing.T) {
	logPath := setupSilentLogDir(t)
	installDir, pf32Path, want := installFullPipelineFixture(t, nil)

	stub := &stubReleaseFetcher{
		release: &latestRelease{Version: "999.0.0"}, // newer than Version
	}
	svc := newUpdateService("0.0.1", stub, nil)
	rc := rcWithWorkaround(runSilentUpdateWithService(context.Background(), svc))
	if rc != 0 {
		t.Fatalf("expected rc=0 on full-pipeline happy path, got %d", rc)
	}

	// Each swap target must contain the NEW content.
	checks := []struct {
		path    string
		manifestName string
	}{
		{filepath.Join(installDir, "go-mapi.exe"), "go-mapi.exe"},
		{filepath.Join(installDir, "go-mapi.dll"), "go-mapi-x64.dll"},
		{pf32Path, "go-mapi-x86.dll"},
	}
	for _, c := range checks {
		got, err := os.ReadFile(c.path)
		if err != nil {
			t.Fatalf("read %s: %v", c.path, err)
		}
		if !bytes.Equal(got, want[c.manifestName]) {
			t.Errorf("%s content: got %q, want %q", c.path, got, want[c.manifestName])
		}
	}

	body := readLogOrFail(t, logPath)
	if !strings.Contains(body, "verified asset OK") {
		t.Errorf("log missing 'verified asset OK': %q", body)
	}
	if !strings.Contains(body, "silent update complete") {
		t.Errorf("log missing 'silent update complete': %q", body)
	}
	// Pitfall 6: no hex digests in log. SHA-256 = 64 hex chars; reject any
	// 40+-char run of [0-9a-f]. Filenames + RFC3339 timestamps stay below
	// that threshold.
	for _, line := range strings.Split(body, "\n") {
		run := 0
		for _, r := range line {
			if (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') {
				run++
				if run >= 40 {
					t.Errorf("log line contains a hex run >=40 chars (suspected SHA-256 leak): %q", line)
					break
				}
			} else {
				run = 0
			}
		}
	}
}

// TestRunSilentUpdate_ChecksumMismatchAborts proves the V12 verify-BEFORE-
// swap invariant end-to-end: a forged manifest causes the pipeline to log
// "verified asset FAILED" and return rc=1 before any swap touches disk.
// The pre-existing OLD installed binary must remain untouched.
func TestRunSilentUpdate_ChecksumMismatchAborts(t *testing.T) {
	logPath := setupSilentLogDir(t)

	// Forged manifest: declares an all-zero digest for go-mapi.exe (mismatches the canned body).
	forged := []byte("0000000000000000000000000000000000000000000000000000000000000000  go-mapi.exe\n" +
		"0000000000000000000000000000000000000000000000000000000000000000  go-mapi-x64.dll\n" +
		"0000000000000000000000000000000000000000000000000000000000000000  go-mapi-x86.dll\n")
	installDir, _, _ := installFullPipelineFixture(t, forged)

	stub := &stubReleaseFetcher{
		release: &latestRelease{Version: "999.0.0"},
	}
	svc := newUpdateService("0.0.1", stub, nil)
	rc := rcWithWorkaround(runSilentUpdateWithService(context.Background(), svc))
	if rc != 1 {
		t.Fatalf("expected rc=1 on checksum mismatch, got %d", rc)
	}

	// Pre-existing OLD binary must not have been swapped.
	got, err := os.ReadFile(filepath.Join(installDir, "go-mapi.exe"))
	if err != nil {
		t.Fatalf("read installed exe: %v", err)
	}
	if string(got) != "OLD" {
		t.Errorf("installed binary was swapped despite verify failure: got %q, want OLD", got)
	}

	body := readLogOrFail(t, logPath)
	if !strings.Contains(body, "verified asset FAILED") {
		t.Errorf("log missing 'verified asset FAILED': %q", body)
	}
}

func TestRunSilentUpdate_FetcherError(t *testing.T) {
	logPath := setupSilentLogDir(t)
	stub := &stubReleaseFetcher{err: errors.New("simulated network failure")}
	svc := newUpdateService("0.0.1", stub, nil)
	rc := rcWithWorkaround(runSilentUpdateWithService(context.Background(), svc))
	if rc != 1 {
		t.Fatalf("expected rc=1 on fetcher error, got %d", rc)
	}
	body := readLogOrFail(t, logPath)
	if !strings.Contains(body, "CheckNow:") {
		t.Errorf("log missing 'CheckNow:' diagnostic: %q", body)
	}
}

func TestRunSilentUpdate_LogTruncatesAtOneMB(t *testing.T) {
	logPath := setupSilentLogDir(t)
	// Pre-create a >1MB log file.
	big := make([]byte, (1<<20)+1024)
	for i := range big {
		big[i] = 'X'
	}
	_ = os.MkdirAll(filepath.Dir(logPath), 0o755)
	if err := os.WriteFile(logPath, big, 0o644); err != nil {
		t.Fatalf("write big log: %v", err)
	}

	stub := &stubReleaseFetcher{release: &latestRelease{Version: "0.0.0"}}
	svc := newUpdateService("9.9.9", stub, nil)
	_ = runSilentUpdateWithService(context.Background(), svc)

	fi, err := os.Stat(logPath)
	if err != nil {
		t.Fatalf("stat log: %v", err)
	}
	if fi.Size() >= 1<<20 {
		t.Errorf("log not truncated: size=%d (expected << 1MB)", fi.Size())
	}
}

func readLogOrFail(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read log %s: %v", path, err)
	}
	return string(b)
}

// rcWithWorkaround is a helper to ensure we don't accidentally return the
// wrong RC in tests due to defer ordering or other side effects.
func rcWithWorkaround(rc int) int {
	return rc
}

// --- Plan 11.1-04 Task 1: atomic-swap primitive tests --------------------

func TestSilentSwapHappyPath(t *testing.T) {
	tmp := t.TempDir()
	installed := filepath.Join(tmp, "binary.exe")
	staged := filepath.Join(tmp, "staged.exe")
	if err := os.WriteFile(installed, []byte("OLD"), 0o644); err != nil {
		t.Fatalf("write installed: %v", err)
	}
	if err := os.WriteFile(staged, []byte("NEW"), 0o644); err != nil {
		t.Fatalf("write staged: %v", err)
	}

	oldPath, err := swapInPlace(staged, installed)
	if err != nil {
		t.Fatalf("swapInPlace: %v", err)
	}

	// installed must now contain NEW.
	got, err := os.ReadFile(installed)
	if err != nil {
		t.Fatalf("read installed: %v", err)
	}
	if string(got) != "NEW" {
		t.Errorf("installed content: got %q, want NEW", got)
	}

	// .old must contain OLD.
	oldBytes, err := os.ReadFile(oldPath)
	if err != nil {
		t.Fatalf("read old: %v", err)
	}
	if string(oldBytes) != "OLD" {
		t.Errorf("old content: got %q, want OLD", oldBytes)
	}

	// staged must no longer exist (renamed away).
	if _, err := os.Stat(staged); !os.IsNotExist(err) {
		t.Errorf("staged should not exist after swap, stat err=%v", err)
	}
}

func TestSilentSwapWithRetry_GivesUpAtDeadline(t *testing.T) {
	tmp := t.TempDir()
	// staged does not exist → swapInPlace will always fail.
	installed := filepath.Join(tmp, "binary.exe")
	staged := filepath.Join(tmp, "does-not-exist.exe")
	if err := os.WriteFile(installed, []byte("OLD"), 0o644); err != nil {
		t.Fatalf("write installed: %v", err)
	}

	// W5 — required seam: drop initial backoff to 10ms so the retry loop
	// runs in milliseconds, not the production 30s.
	testBackoffOverride = 10 * time.Millisecond
	t.Cleanup(func() { testBackoffOverride = 0 })

	start := time.Now()
	_, err := swapWithRetry(staged, installed, 100*time.Millisecond, nopLogger)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("expected error after deadline; got nil")
	}
	if elapsed > 5*time.Second {
		t.Errorf("swapWithRetry took too long: %s — deadline=100ms not honored", elapsed)
	}
}

// --- Plan 11.1-04 Task 2: ChecksumValidator integration tests -----------

func TestSilentChecksumMismatchAborts(t *testing.T) {
	// Build a fake manifest claiming the file's digest is all-zeros but
	// pass content with a different SHA-256. ChecksumValidator must reject.
	fakeManifest := []byte("0000000000000000000000000000000000000000000000000000000000000000  test-asset.bin\n")
	validator := &selfupdate.ChecksumValidator{UniqueFilename: "SHA256SUMS.txt"}

	body := []byte("the actual content has a different sha256")
	if err := validator.Validate("test-asset.bin", body, fakeManifest); err == nil {
		t.Fatal("expected ChecksumValidator to reject mismatched content")
	}
}

// W8 — happy path: prove the ChecksumValidator API shape works for known-good
// input. Without this we'd be relying on the rejection-only test plus manual
// UAT-3 to validate the API contract — too much faith in a third-party
// library signature.
func TestSilentChecksumValidatesKnownGood(t *testing.T) {
	// sha256("test") = 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
	body := []byte("test")
	manifest := []byte("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08  test\n")
	validator := &selfupdate.ChecksumValidator{UniqueFilename: "SHA256SUMS.txt"}

	if err := validator.Validate("test", body, manifest); err != nil {
		t.Fatalf("expected ChecksumValidator to ACCEPT matching content; got err=%v", err)
	}
}

func TestSilentCleansOldOrphans(t *testing.T) {
	tmp := t.TempDir()
	// Create a few orphans + a non-orphan file.
	orphans := []string{
		filepath.Join(tmp, "go-mapi.exe.old.1234"),
		filepath.Join(tmp, "go-mapi.dll.old.5678"),
		filepath.Join(tmp, "go-mapi.exe.old.9999"),
	}
	keep := filepath.Join(tmp, "go-mapi.exe")
	for _, p := range append(orphans, keep) {
		if err := os.WriteFile(p, []byte("X"), 0o644); err != nil {
			t.Fatalf("write %s: %v", p, err)
		}
	}

	cleanupOldOrphans(tmp, nopLogger)

	// All orphans gone.
	for _, p := range orphans {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("orphan %s should be removed; stat err=%v", p, err)
		}
	}
	// Non-orphan preserved.
	if _, err := os.Stat(keep); err != nil {
		t.Errorf("keeper %s should still exist; err=%v", keep, err)
	}
}
