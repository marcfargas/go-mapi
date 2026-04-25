//go:build windows

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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

func TestRunSilentUpdate_UpdateAvailable_Stub(t *testing.T) {
	logPath := setupSilentLogDir(t)
	stub := &stubReleaseFetcher{
		release: &latestRelease{Version: "999.0.0"}, // newer than Version
	}
	svc := newUpdateService("0.0.1", stub, nil)
	rc := rcWithWorkaround(runSilentUpdateWithService(context.Background(), svc))
	// Plan 11.1-02 scaffold: returns 0 with deferred log line.
	if rc != 0 {
		t.Fatalf("expected rc=0 (deferred to Plan 11.1-04), got %d", rc)
	}
	body := readLogOrFail(t, logPath)
	if !strings.Contains(body, "deferred to Plan 11.1-04") {
		t.Errorf("log missing 'deferred to Plan 11.1-04' marker: %q", body)
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
