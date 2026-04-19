---
phase: 09-queue-automode-toasts
plan: "02"
subsystem: settings-persistence
tags: [settings, persistence, atomic-write, windows-syscall, go-backend]
dependency_graph:
  requires: []
  provides:
    - appDataDir() helper (paths.go) — shared path resolution for settings + logging
    - AppSettings struct + loadSettings() + saveSettings() — settings persistence layer
  affects:
    - src/app/paths.go (extended)
    - src/app/settings.go (new)
    - src/app/settings_test.go (new)
tech_stack:
  added: []
  patterns:
    - atomic-write via windows.MoveFileEx(MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)
    - env-var override pattern (GOMAPI_APPDATA_DIR) for test isolation
    - build-tag windows split (no POSIX stub — CI is windows-latest only)
key_files:
  created:
    - src/app/settings.go
    - src/app/settings_test.go
  modified:
    - src/app/paths.go
    - src/app/paths_test.go
decisions:
  - "No POSIX stub for settings.go — CI is windows-latest only (matches sessionend.go / singleinstance.go precedent)"
  - "logging.go not refactored to use appDataDir() — tight scope, works as-is"
  - "MkdirAll uses 0700 (not 0755 from RESEARCH snippet) — matches logging.go precedent for user-private dir"
metrics:
  duration: "~15 minutes"
  completed: "2026-04-19"
  tasks_completed: 2
  files_changed: 4
---

# Phase 9 Plan 2: Settings Persistence Layer Summary

**One-liner:** Settings persistence layer with crash-safe atomic writes via `windows.MoveFileEx(MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)` and env-var test isolation via `GOMAPI_APPDATA_DIR`.

## What Was Built

### Task 1: `appDataDir()` helper (paths.go)

Added `appDataDir()` to `src/app/paths.go` following the exact env-precedence pattern of `watcherDir()`:

1. `GOMAPI_APPDATA_DIR` — test override (allows `t.TempDir()` + `t.Setenv` isolation)
2. `%APPDATA%` — production Windows path → `%APPDATA%\go-mapi`
3. `os.UserConfigDir()` — POSIX fallback (for `go vet` on non-Windows dev machines)
4. `./go-mapi` — final fallback if all above fail

Added `TestAppDataDir_EnvPrecedence` (3 subtests) to `paths_test.go`. `logging.go` intentionally unchanged — tight scope.

**Commit:** `e704191`

### Task 2: `settings.go` — AppSettings + atomic persistence

Created `src/app/settings.go` (`//go:build windows`) with:

- `AppSettings{Mode string}` — Phase 9 ships one field; godoc captures D-13 + D-15
- `loadSettings()` — reads settings.json, returns `{Mode: "manual"}` on ENOENT, corrupt JSON, or unknown mode value; no panic, no crash
- `saveSettings(AppSettings) error` — atomic write pattern: MkdirAll → json.Marshal → CreateTemp → Write/Sync/Close → `windows.MoveFileEx(MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)` → defer cleanup of tmp
- `moveFileAtomic(src, dst)` — wraps `windows.UTF16PtrFromString` + `windows.MoveFileEx`

Created `src/app/settings_test.go` (`//go:build windows`) with 6 tests:
- `TestSaveLoadRoundTrip` — save auto-draft → load returns auto-draft
- `TestLoadDefaultsOnFirstRun` — empty dir → manual default
- `TestLoadDefaultsOnCorruptJSON` — garbage JSON → manual default, no panic
- `TestLoadNormalizesUnknownMode` — unknown mode string → manual default
- `TestSaveOverwritesAtomically` — two saves, second wins, no tmp file leaks
- `TestSaveCreatesMissingDir` — saveSettings creates the directory if absent

All 6 tests pass at `-count 3` (18 runs). `go test -count 1 ./...` full suite: PASS.

**Commit:** `6a48f46`

## Deviations from Plan

### Auto-fixed Issues

None.

### Intentional Scope Adjustments

**1. `MkdirAll` permission 0700 instead of 0755 (from RESEARCH snippet)**
- **Found during:** Task 2 implementation
- **Decision:** Used `0700` (matches `logging.go` precedent for `%APPDATA%\go-mapi\`) rather than the `0755` in the RESEARCH §3 code snippet. Per-user directory should be user-private. This is the correct choice.
- **Files modified:** `src/app/settings.go`

**2. No POSIX stub (`settings_stub.go`)**
- **Found during:** Task 2 — plan listed the stub as an option
- **Decision:** Plan said "Verify before writing the stub." Checked: `sessionend.go` and `singleinstance.go` both use `//go:build windows` with no stubs. CI runs `windows-latest` only for `src/app/...`. Stub is unnecessary.
- **Files NOT created:** `src/app/settings_stub.go`

## Known Stubs

None. This is a pure backend plan — no UI wiring, no frontend stubs. The `AppSettings` type and `loadSettings`/`saveSettings` functions are complete implementations, not placeholders.

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes at trust boundaries introduced beyond what the plan's `<threat_model>` already covers. The `settings.json` file contains only `{"mode":"manual"|"auto-draft"}` — no PII per T-9-04.

## Self-Check

Files exist:
- `src/app/settings.go` — FOUND
- `src/app/settings_test.go` — FOUND
- `src/app/paths.go` — FOUND (modified)
- `src/app/paths_test.go` — FOUND (modified)

Commits exist:
- `e704191` feat(09-02): extract appDataDir() helper into paths.go — FOUND
- `6a48f46` feat(09-02): implement settings persistence layer with atomic write — FOUND

## Self-Check: PASSED
