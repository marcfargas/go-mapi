//go:build windows && !bindings

package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/creativeprojects/go-selfupdate"
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

// httpDoer is the seam that lets tests inject a stub HTTP client returning
// canned manifest + asset bytes. Production uses http.DefaultClient. Mirrors
// the releaseFetcher seam pattern in updates.go.
type httpDoer interface {
	Do(req *http.Request) (*http.Response, error)
}

// silentHTTPClient is the package-level seam for tests. Default is
// http.DefaultClient; tests assign a stub via t.Cleanup teardown.
var silentHTTPClient httpDoer = http.DefaultClient

// installRootOverride lets tests redirect the swap-destination directory
// (the equivalent of $INSTDIR) to a temp directory. Production leaves it
// empty so installRoot() returns os.Executable()'s parent. Mirrors
// testBackoffOverride.
var installRootOverride string

// programFiles32Override lets tests redirect the x86 DLL destination to a
// temp directory. Production leaves it empty so programFiles32GoMapiDLL()
// resolves %ProgramFiles(x86)%\go-mapi\go-mapi.dll.
var programFiles32Override string

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

	// W6: Option A (multi-asset swap) selected per 11.1-03-AUDIT.md. The
	// release pipeline publishes go-mapi-setup.exe, go-mapi.exe, and both
	// DLL bitnesses with matching SHA-256 entries; we download each, verify
	// in-memory before letting bytes hit disk (V12 verify-then-swap), then
	// per-asset MoveFileEx swap-with-retry into $INSTDIR.
	log.printf("update available: latest=%s — beginning download/verify/swap", state.LatestVersion)

	stagingRoot := updatesStagingDir()
	stagingDir := filepath.Join(stagingRoot, "staging")
	if err := os.MkdirAll(stagingDir, 0o755); err != nil {
		log.printf("mkdir staging: %v", err)
		return 1
	}
	cleanupOldOrphans(installRoot(), log.printf)
	cleanupOldOrphans(stagingDir, log.printf)

	// 1. Fetch the manifest first — it's the contract for everything else.
	manifestBytes, err := downloadCappedBody(ctx, checksumsURL, 64*1024)
	if err != nil {
		log.printf("manifest GET: %v", err)
		return 1
	}

	validator := &selfupdate.ChecksumValidator{UniqueFilename: "SHA256SUMS.txt"}

	// 2. Download + verify each asset into the staging dir.
	targets := buildSwapTargets(stagingDir)

	for _, t := range targets {
		if err := downloadAndVerify(ctx, t.downloadURL, manifestBytes, t.manifestName, t.stagedPath, validator, log.printf); err != nil {
			if errors.Is(err, errChecksumFailed) {
				// Pitfall 6: do not %v the validator error — it carries hex
				// digests. The "verified asset FAILED" line is the audit trail.
				log.printf("download/verify %s aborted: checksum mismatch", t.manifestName)
			} else {
				log.printf("download/verify %s aborted: %v", t.manifestName, err)
			}
			return 1
		}
	}

	// 3. All verified — perform swaps. Verify-BEFORE-swap (V12) is enforced
	// by downloadAndVerify above; we never reach this loop with an
	// unverified asset on disk.
	for _, t := range targets {
		if _, err := swapWithRetry(t.stagedPath, t.installedPath, silentUpdateMaxElapsed, log.printf); err != nil {
			log.printf("swap %s aborted: %v", t.manifestName, err)
			return 1
		}
		log.printf("swapped %s", t.manifestName)
	}

	// 4. Cleanup staging dir on success; leave on failure for diagnosis.
	if err := os.RemoveAll(stagingDir); err != nil {
		log.printf("cleanup staging (non-fatal): %v", err)
	}
	log.printf("silent update complete: now running %s", state.LatestVersion)
	return 0
}

// swapTarget describes one binary that needs to be downloaded, verified,
// and swapped during a silent update.
type swapTarget struct {
	manifestName  string // matches the name in SHA256SUMS.txt
	downloadURL   string // GitHub Releases /latest/download/<name>
	stagedPath    string // %ProgramData%\go-mapi\updates\staging\<name>
	installedPath string // final destination ($INSTDIR\go-mapi.exe etc.)
}

// buildSwapTargets returns the Option A asset list (per 11.1-03-AUDIT). The
// installer-only Option B variant would return only go-mapi-setup.exe and a
// different installedPath; not used here. Encapsulated so tests can override
// installRootOverride / programFiles32Override and get the right per-target
// destination paths in one place.
func buildSwapTargets(stagingDir string) []swapTarget {
	root := installRoot()
	pf32DLL := programFiles32GoMapiDLL()
	base := "https://github.com/" + gitHubOwner + "/" + gitHubRepo + "/releases/latest/download/"
	return []swapTarget{
		{
			manifestName:  "go-mapi.exe",
			downloadURL:   base + "go-mapi.exe",
			stagedPath:    filepath.Join(stagingDir, "go-mapi.exe"),
			installedPath: filepath.Join(root, "go-mapi.exe"),
		},
		{
			manifestName:  "go-mapi-x64.dll",
			downloadURL:   base + "go-mapi-x64.dll",
			stagedPath:    filepath.Join(stagingDir, "go-mapi-x64.dll"),
			installedPath: filepath.Join(root, "go-mapi.dll"),
		},
		// x86 DLL: %ProgramFiles(x86)%\go-mapi\go-mapi.dll. installRoot()
		// returns %ProgramFiles%\go-mapi, so derive the x86 sibling path
		// via programFiles32GoMapiDLL().
		{
			manifestName:  "go-mapi-x86.dll",
			downloadURL:   base + "go-mapi-x86.dll",
			stagedPath:    filepath.Join(stagingDir, "go-mapi-x86.dll"),
			installedPath: pf32DLL,
		},
	}
}

// downloadCappedBody GETs `url` and returns the body bounded by `cap` bytes.
// Returns an error if the response status is not 200, the body exceeds the
// cap, or the body cannot be read.
func downloadCappedBody(ctx context.Context, url string, cap int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("silent: new request %s: %w", url, err)
	}
	resp, err := silentHTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("silent: GET %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("silent: GET %s: status %d", url, resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, cap+1))
	if err != nil {
		return nil, fmt.Errorf("silent: read %s: %w", url, err)
	}
	if int64(len(body)) > cap {
		return nil, fmt.Errorf("silent: %s exceeds size cap %d", url, cap)
	}
	return body, nil
}

// errChecksumFailed is the sentinel returned by downloadAndVerify when
// ChecksumValidator rejects an asset. Callers must NOT log this error's
// full text via %v — go-selfupdate embeds the expected/found hex digests
// in its message, which would leak digests into update.log (Pitfall 6).
// Use errors.Is(err, errChecksumFailed) to branch on this case.
var errChecksumFailed = errors.New("silent: checksum validation failed")

// downloadAndVerify GETs the asset at `url`, verifies its SHA-256 against
// the entry for `manifestFilename` in `manifestBytes` BEFORE writing to
// `destPath` (V12 — never let an unverified asset hit disk). On verify
// failure, logs "verified asset FAILED" with the filename only — never the
// hex digest (Pitfall 6) — and returns errChecksumFailed so callers can
// abort without re-logging the validator's hex-leaking error message.
func downloadAndVerify(ctx context.Context, url string, manifestBytes []byte, manifestFilename string, destPath string, validator *selfupdate.ChecksumValidator, log func(string, ...any)) error {
	body, err := downloadCappedBody(ctx, url, downloadSizeCap)
	if err != nil {
		return err
	}

	if err := validator.Validate(manifestFilename, body, manifestBytes); err != nil {
		// Note: the validator's err carries hex digests; we DO NOT propagate
		// it via %w — only the sentinel. Pitfall 6 enforced.
		log("verified asset FAILED for %s — aborting", manifestFilename)
		return errChecksumFailed
	}
	log("verified asset OK for %s", manifestFilename)

	if err := os.WriteFile(destPath, body, 0o644); err != nil {
		return fmt.Errorf("silent: write %s: %w", destPath, err)
	}
	return nil
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
		// time.Sleep — no ctx cancellation wired through swapWithRetry; the
		// outer for-loop's deadline check is the abort signal. (staticcheck
		// S1000/S1037: select-only-with-time.After collapses to time.Sleep.)
		time.Sleep(backoff)
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
// Tests override via installRootOverride to redirect swap destinations to a
// temp dir.
func installRoot() string {
	if installRootOverride != "" {
		return installRootOverride
	}
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Dir(exe)
}

// programFiles32GoMapiDLL returns the absolute path to the x86 MAPI DLL
// installed under %ProgramFiles(x86)%\go-mapi\go-mapi.dll. Tests override
// via programFiles32Override to redirect to a temp dir.
func programFiles32GoMapiDLL() string {
	if programFiles32Override != "" {
		return programFiles32Override
	}
	if pf32 := os.Getenv("ProgramFiles(x86)"); pf32 != "" {
		return filepath.Join(pf32, "go-mapi", "go-mapi.dll")
	}
	return `C:\Program Files (x86)\go-mapi\go-mapi.dll`
}
