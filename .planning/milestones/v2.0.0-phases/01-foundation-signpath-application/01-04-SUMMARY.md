---
plan: 01-04
phase: 01-foundation-signpath-application
requirement: FOUND-04
status: complete
completed: 2026-04-10
---

# Plan 01-04 Summary: GOMAPI_WATCH_DIR env var + CLI flags

## What was built

Added `parseFlags()` to `src/native-host/main.go` that resolves startup configuration from three sources with precedence **CLI flag > env var > default**:

- `--watch-dir DIR` / `GOMAPI_WATCH_DIR` env var — watch directory override (default: `%TEMP%\go-mapi\`)
- `--gmail-api-base URL` — Gmail API base URL override (flag-only, no env var fallback)

The resolved values live in a package-level `hostConfig` struct and are logged at startup via `logInfo` so E2E test authors in Phase 4 can verify from the log file.

## Files modified

- `src/native-host/main.go` — added `parseFlags()`, `hostConfig` struct, renamed `getWatchDir()` → `defaultWatchDir()` (used as pure fallback), switched `handleCreateDraft` from `NewGmailClient` to `NewGmailClientWithBase(token, hostConfig.gmailAPIBase)` at the single call site

## Key decisions

1. **parseFlags runs BEFORE initLogging** so `native-host.log` is created inside the resolved watch dir (not the default) when `--watch-dir` or `GOMAPI_WATCH_DIR` is set.
2. **Unknown args are tolerated** via `flag.ContinueOnError` + `io.Discard` error sink — Chrome's native messaging host passes the extension origin URL as `argv[1]`, which must not kill the host.
3. **Warning suppression accepted, not buffered.** Per CLAUDE.md logging convention, `logInfo` fails silently when `logFile` is nil. Buffering parse warnings to replay after `initLogging()` would not actually improve debuggability for this specific path — documented in code comment.
4. **No env var for `--gmail-api-base`** — scope-limited to what FOUND-04 requires. Only `--gmail-api-base` CLI flag, `--watch-dir` flag + `GOMAPI_WATCH_DIR` env var.
5. **`defaultWatchDir()` retained** as the pure fallback helper. `initLogging()` has a secondary `if logDir == ""` guard as a defensive safety net in case ordering ever regresses.

## Verification

- `go build ./...` → clean (from `src/native-host/`)
- `go vet ./...` → clean
- `go test ./...` → `ok github.com/marcfargas/go-mapi/native-host 0.158s`
- Manual inspection of diff: single-file change, no other files touched

## Scope discipline

- No gmail.go changes beyond the constructor swap at the single call site in main.go
- No watcher changes
- No CI files touched
- No new dependencies (Go stdlib `flag` package only)

## Deviations

**Executor crash recovery:** The initial executor agent crashed with an API 401 mid-execution AFTER writing the complete `main.go` edit but BEFORE committing or writing this SUMMARY.md. The orchestrator manually committed the work after verifying:
1. `go build ./...` clean
2. `go vet ./...` clean
3. `go test ./...` clean
4. Diff contains the complete plan implementation (parseFlags + hostConfig + defaultWatchDir rename + NewGmailClientWithBase call swap)
5. No leftover test files or partial edits

No code was lost or corrupted.

## Next

Wave 2 complete (01-02 + 01-04). Proceeding to Wave 3: Plan 01-08 human-verify checkpoint for SIGN-01 filing.
