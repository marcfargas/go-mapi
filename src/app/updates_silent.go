//go:build windows && !bindings

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

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
