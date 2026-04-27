//go:build windows && !bindings

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows"
)

// Plan 11.1-04 constants.
//
// gitHubOwner / gitHubRepo are reused from updates.go (same package).
const (
	checksumsURL = "https://github.com/" + gitHubOwner + "/" + gitHubRepo +
		"/releases/latest/download/SHA256SUMS.txt"

	// silentUpdateMaxElapsed is the wall-clock cap on the swap retry loop
	// (D-14). After this elapsed, the silent updater gives up and exits 1;
	// the next Scheduled Task trigger picks up where this left off.
	silentUpdateMaxElapsed = 12 * time.Hour

	// swapBackoffInitial is the first sleep between swap attempts.
	// Production uses 30s — non-trivial because a busy box is likely to
	// release the file inside that window. Tests override via
	// testBackoffOverride.
	swapBackoffInitial = 30 * time.Second

	// swapBackoffMax caps the exponential growth (5 minutes). Beyond this
	// the loop just retries every 5 minutes until silentUpdateMaxElapsed.
	swapBackoffMax = 5 * time.Minute

	// downloadSizeCap caps each downloaded asset at 50 MB. The Phase 10
	// installer is well under 20 MB; this is a generous safety margin
	// against a runaway response.
	downloadSizeCap = 50 * 1024 * 1024
)

// testBackoffOverride lets tests override swapBackoffInitial. Production
// leaves it zero so the 30s initial backoff holds. Tests set this to e.g.
// 10*time.Millisecond via t.Cleanup teardown so swap-retry tests run in
// milliseconds rather than 30+ seconds. (W5 fix — without this the retry
// test deadlocks on the production initial backoff.)
var testBackoffOverride time.Duration

// runSilentUpdate is the entry point for `go-mapi.exe --update-check-silent`.
// Returns process exit code (0 = success / no-update available, non-zero =
// diagnostic). Logs to %ProgramData%\go-mapi\updates\update.log; never opens
// a window or initialises the tray. Plan 11.1-02 ships the scaffold; Plan
// 11.1-04 wires download + ChecksumValidator + atomic swap.
//
// runSilentUpdate is the public entry; runSilentUpdateWithService is the
// testable seam (matches the updates.go pattern of newUpdateService taking
// an injectable fetcher).
func runSilentUpdate(ctx context.Context) int {
	fetcher, err := newGitHubReleaseFetcher()
	if err != nil {
		// Open log just to capture the failure for Task Scheduler history.
		log := openSilentLog()
		defer log.close()
		log.printf("init fetcher: %v", err)
		return 1
	}
	svc := newUpdateService(Version, fetcher, nil) // nil logger replaced below
	return runSilentUpdateWithService(ctx, svc)
}

func runSilentUpdateWithService(ctx context.Context, svc *updateService) int {
	log := openSilentLog()
	defer log.close()
	// re-bind svc.log so it writes to the silent-update log
	svc.log = log.printf

	log.printf("silent updater starting (version=%s)", Version)
	state, err := svc.CheckNow(ctx)
	if err != nil {
		log.printf("CheckNow: %v", err)
		return 1
	}
	if !state.UpdateAvailable {
		log.printf("no update available (current=%s)", Version)
		return 0
	}

	// PLAN 11.1-04 SCOPE: download asset → verify SHA-256 via
	// selfupdate.ChecksumValidator{UniqueFilename: "SHA256SUMS.txt"} → atomic
	// swap via MoveFileEx rename-while-running → cleanup *.old.<pid> orphans.
	// Until that lands, log the would-be action and exit success so a
	// Scheduled Task registered by Plan 11.1-05 + Plan 11.1-04 has something
	// to invoke.
	log.printf("update available: latest=%s — download/verify/swap deferred to Plan 11.1-04", state.LatestVersion)
	return 0
}

// silentLog wraps log file open / truncate-at-1MB / append + close so the
// tests can rely on a single seam.
type silentLog struct{ f *os.File }

func openSilentLog() *silentLog {
	stagingDir := updatesStagingDir()
	_ = os.MkdirAll(stagingDir, 0o755)
	logPath := filepath.Join(stagingDir, "update.log")
	if fi, err := os.Stat(logPath); err == nil && fi.Size() > 1<<20 {
		_ = os.Remove(logPath)
	}
	f, ferr := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if ferr != nil {
		fmt.Fprintf(os.Stderr, "[silent] open log %s: %v\n", logPath, ferr)
	}
	return &silentLog{f: f}
}

func (s *silentLog) printf(format string, args ...any) {
	line := fmt.Sprintf("[%s] %s\n",
		time.Now().UTC().Format(time.RFC3339),
		fmt.Sprintf(format, args...))
	if s.f != nil {
		_, _ = s.f.WriteString(line)
	}
	// Also print to stderr so Task Scheduler "Last Run Result" + history capture diagnostics.
	_, _ = os.Stderr.WriteString(line)
}

func (s *silentLog) close() {
	if s.f != nil {
		_ = s.f.Close()
	}
}

// --- Plan 11.1-04 Task 1: atomic-swap primitives ---------------------------

// swapInPlace atomically replaces `installed` with `staged` using the NTFS
// rename-while-running trick. Returns the .old.<pid> path so the caller can
// attempt cleanup. Per D-12: the reboot-delay flag is NEVER used (RDS
// targets do not reboot). Per RESEARCH §Pattern 4 + §Pitfall 4: must be a
// two-step rename (NOT a single MoveFileEx with REPLACE_EXISTING on a
// running EXE — Windows tries to delete the destination first and the
// loader's handle blocks that under non-DELETE share modes from filter
// drivers).
func swapInPlace(staged, installed string) (oldPath string, err error) {
	oldPath = fmt.Sprintf("%s.old.%d", installed, os.Getpid())

	fromInstalled, err := windows.UTF16PtrFromString(installed)
	if err != nil {
		return "", fmt.Errorf("silent: utf16 installed: %w", err)
	}
	toOld, err := windows.UTF16PtrFromString(oldPath)
	if err != nil {
		return "", fmt.Errorf("silent: utf16 old: %w", err)
	}
	// Step 1: installed → installed.old.<pid>. Loader holds FILE_SHARE_DELETE
	// on the running EXE / loaded DLL; rename succeeds even while it's
	// "in use".
	if err := windows.MoveFileEx(fromInstalled, toOld, windows.MOVEFILE_REPLACE_EXISTING); err != nil {
		return "", fmt.Errorf("silent: rename installed→old: %w", err)
	}

	fromStaged, err := windows.UTF16PtrFromString(staged)
	if err != nil {
		// Roll back step 1 best-effort.
		_ = windows.MoveFileEx(toOld, fromInstalled, windows.MOVEFILE_REPLACE_EXISTING)
		return oldPath, fmt.Errorf("silent: utf16 staged: %w", err)
	}
	toInstalled, err := windows.UTF16PtrFromString(installed)
	if err != nil {
		_ = windows.MoveFileEx(toOld, fromInstalled, windows.MOVEFILE_REPLACE_EXISTING)
		return oldPath, fmt.Errorf("silent: utf16 installed-target: %w", err)
	}
	// Step 2: staged → installed. Plain rename — destination just freed.
	if err := windows.MoveFileEx(fromStaged, toInstalled, 0); err != nil {
		// Best-effort rollback so we don't leave the user without a binary.
		_ = windows.MoveFileEx(toOld, fromInstalled, windows.MOVEFILE_REPLACE_EXISTING)
		return oldPath, fmt.Errorf("silent: rename staged→installed: %w", err)
	}
	return oldPath, nil
}

// swapWithRetry retries swapInPlace with exponential backoff. Handles the
// ERROR_SHARING_VIOLATION case where Defender or a filter driver briefly
// holds the file without FILE_SHARE_DELETE (Pitfall 4). Per D-13: never
// WM_CLOSE the running app — the retry loop IS the backpressure. Per D-14:
// give up at maxElapsed (caller passes silentUpdateMaxElapsed = 12h).
func swapWithRetry(staged, installed string, maxElapsed time.Duration, log func(string, ...any)) (string, error) {
	deadline := time.Now().Add(maxElapsed)
	backoff := swapBackoffInitial
	if testBackoffOverride > 0 {
		backoff = testBackoffOverride
	}
	var lastErr error
	attempt := 0
	for time.Now().Before(deadline) {
		attempt++
		old, err := swapInPlace(staged, installed)
		if err == nil {
			if attempt > 1 {
				log("swap succeeded on attempt %d (after %d retries)", attempt, attempt-1)
			}
			return old, nil
		}
		lastErr = err
		log("swap attempt %d failed; retrying in %s (err=%v)", attempt, backoff, err)
		select {
		case <-time.After(backoff):
		}
		if backoff < swapBackoffMax {
			backoff *= 2
			if backoff > swapBackoffMax {
				backoff = swapBackoffMax
			}
		}
	}
	return "", fmt.Errorf("silent: swap exceeded %s: %w", maxElapsed, lastErr)
}

// cleanupOldOrphans best-effort removes *.old.* files left from prior swaps.
// The .old.<pid> file is held by the running process's loader handle until
// that process exits; this cleanup runs at silent-update start so each
// cycle clears the previous cycle's orphan. Failures are silent — the file
// is still loader-locked, next cycle will try again.
func cleanupOldOrphans(dir string, log func(string, ...any)) {
	matches, err := filepath.Glob(filepath.Join(dir, "*.old.*"))
	if err != nil {
		log("cleanup glob: %v", err)
		return
	}
	for _, m := range matches {
		if err := os.Remove(m); err != nil {
			// Silent — file likely still held by a running process.
			continue
		}
		log("cleaned orphan: %s", filepath.Base(m))
	}
}

// installRoot returns the directory containing this binary ($INSTDIR for
// installed instances). Resolved from os.Executable() so we never embed a
// literal path. Returns "" if Executable() fails (test environments).
func installRoot() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Dir(exe)
}
