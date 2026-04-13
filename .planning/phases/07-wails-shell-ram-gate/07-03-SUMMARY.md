---
phase: 07-wails-shell-ram-gate
plan: 03
subsystem: shell
tags: [go, wails, windows, single-instance, session-end, watcher, fsnotify, tdd]

# Dependency graph
requires: ["07-01", "07-02"]
provides:
  - "Named mutex (Local\\ scope) + named-event raise transport in src/app/singleinstance.go"
  - "WM_QUERYENDSESSION handler with prompt-return WndProc + bounded 2s async drain"
  - "mapi.EmailWatcher folded into Wails app via watcherBridge (1-slot buffered channel dispatcher)"
  - "GetQueue() returns live watcher snapshot (replaces Plan 02 nil stub)"
  - "RFC3339 [INFO]/[ERROR] file logger at %APPDATA%\\go-mapi\\app.log"
  - "paths.go watcherDir() mirrors native-host defaultWatchDir() + GOMAPI_WATCH_DIR override"
affects: ["07-04"]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "GetLastError-based ERROR_ALREADY_EXISTS detection (not go err return) — REVIEWS HIGH fix"
    - "Named event raise transport (Local\\go-mapi-raise-v3) replaces FindWindowW — REVIEWS HIGH fix"
    - "WndProc prompt-return: fires non-blocking sessionEndSignal + returns 1, no I/O — REVIEWS HIGH fix"
    - "runBoundedDrain: 2-second context.WithTimeout + os.Exit fallback for logoff safety"
    - "1-slot buffered channel + sync.Once Close for idempotent coalescing bridge"
    - "newWatcherBridgeWithEmitter injectable emitter for test isolation"
    - "EventsEmit ONLY in dispatcher goroutine or controlled startup error path (Pitfall §5)"

key-files:
  created:
    - "src/app/singleinstance.go — Local\\ mutex + named event with GetLastError-based detection"
    - "src/app/singleinstance_test.go — 8 unit tests: Local\\ scope, lifecycle, raise signal"
    - "src/app/sessionend.go — hidden message-only HWND, WndProc prompt-return, runBoundedDrain"
    - "src/app/sessionend_test.go — 7 unit tests: constants, WndProc timing, drain idempotency"
    - "src/app/watcher_bridge.go — WatcherCallback impl with 1-slot channel + dispatch goroutine"
    - "src/app/watcher_bridge_test.go — 7 unit tests: non-blocking, coalescing, Close idempotency"
    - "src/app/logging.go — [INFO]/[ERROR] RFC3339 logger at %APPDATA%\\go-mapi\\app.log"
    - "src/app/paths.go — watcherDir() computation matching native-host convention"
  modified:
    - "src/app/app.go — extended: new fields (bridge, sessionEndCancel, shutdownCtx/Cancel); startup wires all three concerns; GetQueue returns live snapshot"
    - "src/app/main.go — acquireSingleInstance before wails.Run, early exit on raised=true"
    - "src/app/frontend/src/App.svelte — EventsOn('queue-error') listener added"

key-decisions:
  - "GetLastError-based detection: CreateMutex returns valid handle even when ERROR_ALREADY_EXISTS; error reported via GetLastError not err return (REVIEWS HIGH fix)"
  - "Named event raise transport: Local\\go-mapi-raise-v3 + OpenEvent+SetEvent from second instance; FindWindowW eliminated from primary path (REVIEWS HIGH fix)"
  - "WndProc prompt-return: sessionEndWndProc fires only sessionEndSignal() (non-blocking) then returns 1; no I/O (REVIEWS HIGH fix)"
  - "PostMessage(WM_QUIT) to HWND for pump shutdown: PostQuitMessage posts to current thread not pump goroutine's thread — switched to PostMessage to correct thread"
  - "Injectable emitter for tests: newWatcherBridgeWithEmitter avoids Wails runtime panics with background context"
  - "Drain unified via runBoundedDrain: both session-end and normal shutdown paths cancel same context; watcher.Stop + bridge.Close called exactly once from drain func"

requirements-completed: [SHELL-04, SHELL-05, SHELL-06, QUAL-04]

# Metrics
duration: 90min
completed: 2026-04-13
---

# Phase 07 Plan 03: Windows Lifecycle (Single-instance, Session-end, Watcher fold-in) Summary

**Added single-instance mutex with named-event raise transport, WM_QUERYENDSESSION handler with prompt-return WndProc and bounded async drain, and mapi.EmailWatcher folded into Wails app via 1-slot coalescing bridge; GetQueue now returns live snapshot replacing Plan 02 nil stub.**

## Performance

- **Duration:** ~90 min
- **Started:** 2026-04-13
- **Completed:** 2026-04-13
- **Tasks:** 3 auto (+ 1 human-verify checkpoint PENDING)
- **Files:** 8 created, 3 modified

## Accomplishments

- `singleinstance.go`: `Local\go-mapi-singleton-v3` mutex with `GetLastError`-based `ERROR_ALREADY_EXISTS` detection; `Local\go-mapi-raise-v3` named event as primary raise transport; `waitForRaiseSignal` dispatcher goroutine in `App.startup`
- `sessionend.go`: hidden message-only HWND; `sessionEndWndProc` returns 1 (TRUE) immediately and fires only a non-blocking signal; `runBoundedDrain` with 2-second `context.WithTimeout` + `os.Exit(0)` fallback
- `watcher_bridge.go`: 1-slot buffered channel with drop-policy; dispatcher goroutine calls `EventsEmit("queue-update")` off watcher goroutine path; `sync.Once` idempotent `Close()`
- `logging.go`: RFC3339 `[INFO]`/`[ERROR]` file logger at `%APPDATA%\go-mapi\app.log`; no email content logged (T-07-22 mitigated)
- `paths.go`: `watcherDir()` mirrors native-host `defaultWatchDir()` + `GOMAPI_WATCH_DIR` override
- `app.go`: `GetQueue()` returns live `watcher.Snapshot()` replacing Plan 02 nil stub
- `App.svelte`: `EventsOn('queue-error')` listener wired
- 22 total unit tests across 3 new test files; all pass; `wails build -clean` produces working binary

## Task Commits

1. **Task 1: Single-instance mutex + named-event raise transport** — `7951b3e`
2. **Task 2: WM_QUERYENDSESSION handler + watcher bridge type** — `d6fd798`
3. **Task 3: Watcher fold-in + GetQueue live snapshot** — `53609a4`

## Mutex and Named Event Confirmation

| Constant | Value | Scope |
|----------|-------|-------|
| `mutexName` | `Local\go-mapi-singleton-v3` | Per-session (RDS isolated) |
| `raiseEventName` | `Local\go-mapi-raise-v3` | Per-session (RDS isolated) |

Both use `Local\` scope — each RDS user session owns exactly one instance. `Global\` scope was explicitly NOT used.

## GetLastError-based Detection Confirmation

```go
handle, createErr := windows.CreateMutex(nil, false, name)
// GetLastError MUST be called before any other syscall on this goroutine
lastErr := windows.GetLastError()
// ...
if lastErr == windows.ERROR_ALREADY_EXISTS {
    _ = windows.CloseHandle(handle) // close duplicate handle
    // signal first instance...
    return true, nil
}
```

`err` return from `CreateMutex` is NOT used for the already-exists check — `GetLastError()` is called immediately after `CreateMutex` per Win32 semantics (REVIEWS HIGH fix).

## Raise Transport Confirmation

Primary transport: `CreateEvent` → `OpenEvent` + `SetEvent`. `FindWindowW` does NOT appear in any production code path (only in comments explaining why it was eliminated).

## WndProc Return-Timing Evidence (Test 2 confirmed)

`TestSessionEndWndProcReturnsTrueImmediately` asserts:
- Return value == 1 (TRUE)
- Elapsed time < 10ms
- `sessionEndSignal` callback fires before return

The WndProc branch contains only `sessionEndSignal()` + `return 1`. No I/O, no `watcher.Stop`, no `bridge.Close` inside the WndProc (grep verified: `grep -A6 "case wmQueryEndSession" src/app/sessionend.go`).

## Bounded Drain Timeout Evidence

`runBoundedDrain` uses `context.WithTimeout(context.Background(), 2*time.Second)`:
- If drain completes in time: returns normally
- If drain exceeds 2s: `logError("session-end drain exceeded 2s timeout; forcing os.Exit")` → `os.Exit(0)`

This ensures Windows logoff is never blocked past 2 seconds regardless of watcher state.

## watcher.Stop + bridge.Close Idempotency Confirmation

- `watcher.Stop()`: `sync.Once` from Plan 01 Test 7 — proven idempotent
- `bridge.Close()`: `sync.Once` guards `close(b.done)` — calling twice does not panic (Task 3 Test 5 `TestBridgeCloseIdempotent`)
- Both wrapped in `if != nil` guards in `runBoundedDrain` drain function

## EventsEmit Audit

| Location | Goroutine | Event |
|----------|-----------|-------|
| `watcher_bridge.go:29` inside `dispatch()` | dispatcher goroutine (NOT watcher goroutine) | `queue-update` |
| `app.go:55` startup goroutine | one-shot error path | `queue-error` |
| `app.go:63` startup goroutine | one-shot error path | `queue-error` |

`EventsEmit` is never called from `OnQueueChanged` or any watcher-held-lock path. Pitfall §5 compliance confirmed.

## Cross-Module Test Results

```
ok  github.com/marcfargas/go-mapi/native-host
ok  github.com/marcfargas/go-mapi/app
```

Both modules pass. QUAL-04 met. (`-race` not supported on windows/arm64 dev machine — same constraint as Plan 01; CI on non-ARM64 host is the `-race` verification environment.)

## Build Verification

`wails build -clean` in `src/app/` produced `src/app/build/bin/go-mapi.exe` successfully in 13.7s.

## Known Stubs

None — all data flows are wired:
- `GetQueue()` returns `a.watcher.Snapshot()` (live watcher state)
- `EventsEmit("queue-update")` fires on every queue change
- `EventsOn("queue-error")` wired in Svelte to show error state

## Human-Verify Checkpoint (Task 4) — PENDING

**Status: AWAITING USER VERIFICATION**

The plan requires the user to run `src/app/build/bin/go-mapi.exe` and verify 10 steps:

1. Startup with no flash (tray icon only)
2. Tray tooltip: `go-mapi — watching for emails`
3. Right-click menu: Show + Quit only
4. Show window (480×600, empty-state card)
5. Left-click toggle behavior
6. Close to tray (X hides, process stays)
7. Single-instance + raise (second launch exits, first raises)
8. Live queue update (drop fixture to `%TEMP%\go-mapi\`, row appears)
9. Logoff clean exit (< 5s, no hung process, no half-written JSON)
10. Quit via tray menu

Steps 7, 8, 9 are REQUIRED (not deferrable). This checkpoint is documented in the orchestrator's SUMMARY record.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `PostQuitMessage` posts to wrong thread**
- **Found during:** Task 2 sessionend_test — `TestRegisterSessionEndHandlerReturnsCancel` timed out (cancel() hung)
- **Issue:** `procPostQuitMsg.Call(0)` posts `WM_QUIT` to the CALLING thread's message queue, not the goroutine running the message pump (different OS thread). The pump never received WM_QUIT and blocked indefinitely on `GetMessage`.
- **Fix:** Replaced `PostQuitMessage` with `PostMessage(hwnd, WM_QUIT, 0, 0)` which posts to the thread owning the HWND (the pump goroutine). Added 500ms timeout in cancel to avoid blocking shutdown if pump doesn't respond.
- **Files modified:** `src/app/sessionend.go` (added `procPostMessage`, switched to `procPostMessage.Call(hwnd, wmQuit, 0, 0)`)
- **Commit:** `d6fd798`

**2. [Rule 1 - Bug] Test `TestDispatcherCoalesces` — false failure on ARM64**
- **Found during:** Task 3 test run — 50 concurrent `OnQueueChanged` calls all individually emitted because dispatcher ran between each call
- **Issue:** The original test relied on goroutine scheduling to flood the 1-slot channel before the dispatcher could drain. On ARM64, goroutine scheduling is faster and the dispatcher emptied the slot between each sender goroutine.
- **Fix:** Rewrote test to explicitly block the dispatcher (via a blocking `dispatchBlocked` channel) while 50 calls are queued, then unblock to verify exactly 1 emit. This correctly validates the 1-slot coalesce behavior regardless of scheduler.
- **Files modified:** `src/app/watcher_bridge_test.go`
- **Commit:** `53609a4`

**3. [Rule 3 - Blocking] Wails runtime panic in tests — non-Wails context**
- **Found during:** Task 3 test run — `wruntime.EventsEmit` logged fatal error when called with `context.Background()`
- **Issue:** `newWatcherBridge` hard-coded the Wails emitter; tests using `context.Background()` triggered Wails runtime validation.
- **Fix:** Added `newWatcherBridgeWithEmitter(ctx, onError, emitFn)` as the base constructor; `newWatcherBridge` delegates to it with the real Wails emitter. Tests use `newWatcherBridgeWithEmitter` with a `noopEmitter`. No production behavior changed.
- **Files modified:** `src/app/watcher_bridge.go`, `src/app/watcher_bridge_test.go`
- **Commit:** `53609a4`

---

**Total deviations:** 3 (all auto-fixed Rules 1+3)

## Threat Surface Scan

All implemented threats from plan's `<threat_model>` are mitigated:

| ID | Component | Status |
|----|-----------|--------|
| T-07-20 | Named event spoofing | Accepted (local-user attack, benign UX effect) |
| T-07-21 | Half-written JSON on logoff | Mitigated: `runBoundedDrain` + `watcher.Stop()` idempotent |
| T-07-22 | App log leaking email content | Mitigated: `logging.go` logs only infrastructure events; `grep -rn "msg\.Body\|msg\.Subject" src/app/logging.go src/app/app.go src/app/watcher_bridge.go` = 0 hits |
| T-07-23 | Log written to per-user path | Mitigated: `os.Getenv("APPDATA")` path |
| T-07-24 | EventsEmit flooding | Mitigated: 1-slot drop-policy bridge |
| T-07-25 | Watcher deadlock against WndProc | Mitigated: bridge channel decouples paths |
| T-07-26 | Logoff blocked by slow shutdown | Mitigated: WndProc returns in <10ms, 2s drain ceiling |
| T-07-27 | Race on double watcher.Stop/bridge.Close | Mitigated: `sync.Once` + idempotent Stop |

## Self-Check: PASSED

**Files verified:**
- FOUND: `src/app/singleinstance.go`
- FOUND: `src/app/singleinstance_test.go`
- FOUND: `src/app/sessionend.go`
- FOUND: `src/app/sessionend_test.go`
- FOUND: `src/app/watcher_bridge.go`
- FOUND: `src/app/watcher_bridge_test.go`
- FOUND: `src/app/logging.go`
- FOUND: `src/app/paths.go`
- FOUND: `src/app/app.go` (extended)
- FOUND: `src/app/main.go` (updated)
- FOUND: `src/app/frontend/src/App.svelte` (updated)

**Commits verified:**
- `7951b3e` — feat(07-03): single-instance mutex + named-event raise transport (Task 1)
- `d6fd798` — feat(07-03): WM_QUERYENDSESSION handler + watcher bridge type (Task 2)
- `53609a4` — feat(07-03): watcher fold-in + GetQueue live snapshot (Task 3)
- `9322616` — chore(07-03): update go.mod direct dep + regenerate wailsjs bindings

**Build verified:** `wails build -clean` → `src/app/build/bin/go-mapi.exe` in 13.7s ✓

**Tests verified:**
- `src/native-host`: ok (0 failures)
- `src/app`: ok (0 failures)

**Checkpoint note:** Task 4 (human-verify) is a blocking checkpoint. Plan 04 must not begin until Task 4 is approved by the user.
