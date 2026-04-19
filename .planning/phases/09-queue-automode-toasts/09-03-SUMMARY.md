---
phase: 09-queue-automode-toasts
plan: "03"
subsystem: automode-goroutine
tags: [automode, goroutine, fanout, invalid-grant, backlog-skip, mark-processed-idempotent, race-safe]
dependency_graph:
  requires:
    - phase: 09-01
      provides: loosened-coalesce-assertion (TestDispatcherCoalesces), green CI baseline
    - phase: 09-02
      provides: AppSettings struct + loadSettings/saveSettings + defaultMode constant
  provides:
    - automode goroutine (drain loop, draftOne, classifyAutomodeError, inflight dedup)
    - automodeWake 1-slot channel in watcherBridge (RESEARCH §4 Option ii fanout)
    - backlogSkip set (D-10 invalid_grant post-reauth semantics)
    - MarkProcessed/Delete idempotent on unknown id (RESEARCH §7, T-3 mitigation)
    - App struct helpers: isPaused/SetPaused/getMode/setMode/isBacklogSkipped/markBacklogSkipped/pruneBacklogSkip
  affects:
    - 09-04 (tray + pause-watching menu — uses isPaused/SetPaused/getMode)
    - 09-05 (mode toggle UI binding — uses getMode/setMode Wails bindings)
    - 09-06 (toast notifications — uses auto-draft-result event, MarkProcessed idempotent)
tech_stack:
  added: []
  patterns:
    - dual-1-slot-channel fanout (pending + automodeWake fed by same OnQueueChanged)
    - inflight-map dedup guard (tryAcquire/release around draftOne)
    - backlog-skip set (in-memory, pruned on every queue-update, never persisted)
    - idempotent watcher ops (MarkProcessed/Delete return nil on unknown id)
    - gmailBaseURLOverride package var for httptest injection in automode tests
key_files:
  created:
    - src/app/automode.go
    - src/app/automode_test.go
  modified:
    - src/app/app.go
    - src/app/watcher_bridge.go
    - src/app/watcher_bridge_test.go
    - internal/mapi/watcher.go
    - internal/mapi/watcher_test.go
key-decisions:
  - "automodeWake is a second independent 1-slot channel on watcherBridge (RESEARCH §4 Option ii) — UI queue-update latency decoupled from Gmail API latency"
  - "drain() halts on first ErrInvalidGrant (D-10: one summary event not per-email spam); markBacklogSkipped called inside draftOne before emit"
  - "gmailBaseURLOverride package var added to automode.go — injects httptest.Server into draftOne without modifying GmailClient API"
  - "automode_test.go is //go:build windows only — matches sessionend.go/settings.go/singleinstance.go precedent for tests that exercise Windows-specific code paths (MakeAuthenticatedGmailCall → auth.go → keyring)"
  - "SetAfterDispatch hook on watcherBridge (not a callback on the bridge itself) — avoids circular dependency between bridge and App"
requirements_closed: [QUEUE-04, QUEUE-05, QUEUE-06, QUAL-03, QUAL-04]
duration: "~45 minutes"
completed: "2026-04-19"
---

# Phase 9 Plan 03: Automode Goroutine + Backlog-Skip + Idempotent Watcher Summary

**Automode drain goroutine with dual-channel fanout, inflight dedup, invalid_grant backlog-skip (D-10), and idempotent MarkProcessed/Delete (RESEARCH §7 T-3 mitigation) — all verified under 10 test scenarios.**

## Performance

- **Duration:** ~45 minutes
- **Started:** 2026-04-19T15:05:00Z
- **Completed:** 2026-04-19T15:30:00Z
- **Tasks:** 3
- **Files modified:** 7

## Accomplishments

- Made `MarkProcessed` and `Delete` idempotent on unknown IDs — second call returns nil instead of error. Enables toast activation + automode double-signal tolerance (RESEARCH §7, T-3 mitigation).
- Extended `watcherBridge` with a second independent `automodeWake` 1-slot channel fed by `OnQueueChanged`. Automode goroutine wakes on queue change without blocking the dispatcher's queue-update emit path (RESEARCH §4 Option ii).
- Implemented `automode.go` with full drain loop: mode/pause gates, inflight dedup via `tryAcquire`, invalid_grant halt-and-backlog-skip (D-10), per-email `auto-draft-result` events, 30s safety ticker, privacy-safe logging (id prefix only, QUAL-03).
- Added `App` struct fields + helpers: `pauseMu/paused`, `settingsMu/settings`, `automode`, `backlogSkipMu/backlogSkip`, plus `isPaused/SetPaused/getMode/setMode/isBacklogSkipped/markBacklogSkipped/pruneBacklogSkip`.
- Wired `pruneBacklogSkip` into `bridge.SetAfterDispatch` so dismissed/manually-drafted emails leave the backlog-skip set without a session-duration memory leak.
- 10 automode test scenarios + 3 watcher idempotency tests + 2 watcher_bridge channel tests all pass at count 5-20.

## Task Commits

| # | Name | Commit | Files |
|---|------|--------|-------|
| 1 | Make MarkProcessed + Delete idempotent on unknown id | 0da4409 | internal/mapi/watcher.go, internal/mapi/watcher_test.go |
| 2 | Extend watcherBridge with automodeWake + TestAutomodeWakeCoalesces | 38265ed | src/app/watcher_bridge.go, src/app/watcher_bridge_test.go |
| 3 | Implement automode.go + App struct fields + backlog-skip + tests | bd456a1 | src/app/automode.go, src/app/automode_test.go, src/app/app.go |

## Files Created/Modified

- `internal/mapi/watcher.go` — MarkProcessed + Delete idempotent on unknown id; updated godoc citing RESEARCH §7
- `internal/mapi/watcher_test.go` — Updated _NotFound_ tests to expect nil; added TestMarkProcessedIdempotent, TestDeleteIdempotent, TestMarkProcessedUnknownIdReturnsNil
- `src/app/watcher_bridge.go` — Added `automodeWake chan struct{}`, fan-out in OnQueueChanged, `AutomodeWake()` accessor, `SetAfterDispatch()` hook, afterDispatch call in dispatch()
- `src/app/watcher_bridge_test.go` — Added TestAutomodeWakeCoalesces (Test 8) and TestOnQueueChangedFeedsBothChannels (Test 9)
- `src/app/automode.go` — New: automode struct, newAutomode/newAutomodeWithEmitter, start/stop/loop/drain/draftOne/tryAcquire/release/classifyAutomodeError/safeIDPrefix, gmailBaseURLOverride package var
- `src/app/automode_test.go` — New (windows build tag): 10 test scenarios covering all branches
- `src/app/app.go` — New fields (pauseMu, paused, settingsMu, settings, automode, backlogSkipMu, backlogSkip), updated NewApp, startup (load settings + start automode + SetAfterDispatch), shutdown (stop automode), new helpers

## Decisions Made

- `automodeWake` is a second independent 1-slot channel fed by the same `OnQueueChanged`. This is RESEARCH §4 Option (ii): two independent consumers on the same signal. UI queue-update latency is fully decoupled from Gmail API latency.
- `drain()` halts on first `ErrInvalidGrant` (D-10 exact semantics: one summary event per invalid_grant burst, not one per email). `markBacklogSkipped` is called inside `draftOne` before the emit so the backlog-skip set is always populated before the caller sees the error.
- `gmailBaseURLOverride` package-level var in `automode.go` — injects an httptest.Server into `draftOne` without modifying the `GmailClient` API. Mirrors the `tokenEndpointOverride` / `revokeEndpointOverride` seam pattern in auth.go.
- `automode_test.go` uses `//go:build windows` — matches the precedent of `sessionend.go`, `settings.go`, `singleinstance.go`. The `MakeAuthenticatedGmailCall` path (via auth.go's `refreshIfNeededLocked`) compiles on all platforms but the test's SetTrayError call reaches `tray.go` which is Windows-only.
- `SetAfterDispatch` hook on bridge (not a direct callback into App) — avoids circular imports; App wires the hook in startup after both bridge and watcher exist.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] gmailBaseURLOverride injection seam added to automode.go**
- **Found during:** Task 3 (automode_test.go implementation)
- **Issue:** Plan noted that `GmailClient` base URL injection was needed for tests but asked to "verify at read-first time." The existing `NewGmailClientWithBase` constructor was already present in `internal/mapi/gmail.go`. However, `draftOne` always called `mapi.NewGmailClient(token)` (no URL override). Tests pointed at a production Gmail URL would fail and potentially make real network calls.
- **Fix:** Added `var gmailBaseURLOverride string` in `automode.go` and changed `draftOne` to call `mapi.NewGmailClientWithBase(token, gmailBaseURLOverride)`. Empty string falls back to `GmailAPIBase` (NewGmailClientWithBase semantics). No change to `internal/mapi/gmail.go` needed.
- **Files modified:** `src/app/automode.go`
- **Committed in:** bd456a1 (Task 3 commit)

## Known Stubs

None. All behavior is fully implemented. `auto-draft-result` events are emitted for both success and failure paths. The `getMode`/`setMode`/`isPaused`/`SetPaused` helpers are complete — Plan 04/05 will wire the Wails bindings that expose them to the frontend.

## Threat Flags

No new network endpoints or auth paths beyond what the plan's `<threat_model>` already covers. The `auto-draft-result` event is a client-to-frontend one-way notification (no data flows back). The `gmailBaseURLOverride` var is test-only (empty in production).

## Self-Check

Files exist:
- `src/app/automode.go` — FOUND
- `src/app/automode_test.go` — FOUND
- `src/app/app.go` — FOUND (modified)
- `src/app/watcher_bridge.go` — FOUND (modified)
- `src/app/watcher_bridge_test.go` — FOUND (modified)
- `internal/mapi/watcher.go` — FOUND (modified)
- `internal/mapi/watcher_test.go` — FOUND (modified)

Commits exist:
- 0da4409: feat(09-03): make MarkProcessed + Delete idempotent on unknown id
- 38265ed: feat(09-03): extend watcherBridge with automodeWake 1-slot channel
- bd456a1: feat(09-03): implement automode goroutine, backlog-skip, App struct fields

## Self-Check: PASSED
