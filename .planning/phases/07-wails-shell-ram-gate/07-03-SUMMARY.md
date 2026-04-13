---
phase: 07-wails-shell-ram-gate
plan: 03
subsystem: shell
tags: [go, wails, windows, single-instance, session-end, watcher, fsnotify, tdd, tray-lifecycle]

# Dependency graph
requires: ["07-01", "07-02"]
provides:
  - "Named mutex (Local\\ scope) + named-event raise transport in src/app/singleinstance.go"
  - "WM_QUERYENDSESSION handler with prompt-return WndProc + bounded 2s async drain"
  - "mapi.EmailWatcher folded into Wails app via watcherBridge (1-slot buffered channel dispatcher)"
  - "GetQueue() returns live watcher snapshot (replaces Plan 02 nil stub)"
  - "RFC3339 [INFO]/[ERROR] file logger at %APPDATA%\\go-mapi\\app.log"
  - "paths.go watcherDir() mirrors native-host defaultWatchDir() + GOMAPI_WATCH_DIR override"
  - "Tray toggle + Quit menu + single-instance verified end-to-end under human-verify checkpoint"
affects: ["07-04"]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "errors.Is(err, windows.ERROR_ALREADY_EXISTS) on CreateMutex/CreateEvent — canonical detection (Bug C fix, supersedes initial GetLastError approach)"
    - "Named event raise transport (Local\\go-mapi-raise-v3) replaces FindWindowW — REVIEWS HIGH fix"
    - "WndProc prompt-return: fires non-blocking sessionEndSignal + returns 1, no I/O — REVIEWS HIGH fix"
    - "runBoundedDrain: 2-second context.WithTimeout + os.Exit fallback for logoff safety"
    - "1-slot buffered channel + sync.Once Close for idempotent coalescing bridge"
    - "newWatcherBridgeWithEmitter injectable emitter for test isolation"
    - "EventsEmit ONLY in dispatcher goroutine or controlled startup error path (Pitfall §5)"
    - "systray.Run on a dedicated runtime.LockOSThread'd goroutine (Bug A precursor — RunWithExternalLoop pumps messages on the wrong OS thread so right-click never dispatches)"
    - "App-tracked visibility (visibilityMu + visible bool) — Wails exposes no WindowIsVisible; WindowIsNormal is not a visibility proxy"
    - "intentionalQuit atomic.Bool gate — OnBeforeClose distinguishes X-button (hide-to-tray) from tray Quit menu (allow terminate)"

key-files:
  created:
    - "src/app/singleinstance.go — Local\\ mutex + named event with canonical err-based ERROR_ALREADY_EXISTS detection"
    - "src/app/singleinstance_test.go — 9 unit tests: Local\\ scope, lifecycle, raise signal, Bug C regression"
    - "src/app/sessionend.go — hidden message-only HWND, WndProc prompt-return, runBoundedDrain"
    - "src/app/sessionend_test.go — 7 unit tests: constants, WndProc timing, drain idempotency"
    - "src/app/watcher_bridge.go — WatcherCallback impl with 1-slot channel + dispatch goroutine"
    - "src/app/watcher_bridge_test.go — 7 unit tests: non-blocking, coalescing, Close idempotency"
    - "src/app/logging.go — [INFO]/[ERROR] RFC3339 logger at %APPDATA%\\go-mapi\\app.log"
    - "src/app/paths.go — watcherDir() computation matching native-host convention"
  modified:
    - "src/app/app.go — App struct extended (bridge, sessionEndCancel, shutdownCtx/Cancel, visibilityMu, visible, intentionalQuit); startup wires all three concerns; beforeClose gates on intentionalQuit; GetQueue returns live snapshot"
    - "src/app/main.go — acquireSingleInstance before wails.Run; os.Exit(0) on second-instance; HideWindowOnClose removed so OnBeforeClose reaches X-button path"
    - "src/app/tray.go — systray.Run on LockOSThread'd goroutine; toggleWindow consults app-tracked visibility; requestQuit() sets intentionalQuit before wruntime.Quit"
    - "src/app/frontend/src/App.svelte — EventsOn('queue-error') listener added"

key-decisions:
  - "Canonical err-based detection for CreateMutex/CreateEvent: errors.Is(err, windows.ERROR_ALREADY_EXISTS) on the wrapper's return value. The initial GetLastError-based approach (guided by REVIEWS HIGH) was empirically wrong in Go — other goroutines/syscalls on the same OS thread can clobber per-thread last-error between CreateMutex and GetLastError. The //sys directive '[failretval == 0 || e1 == ERROR_ALREADY_EXISTS]' in x/sys/windows already surfaces the error reliably."
  - "Named event raise transport (Local\\go-mapi-raise-v3): replaces FindWindowW per REVIEWS HIGH (title-spoofing / locale / timing risk)"
  - "WndProc prompt-return: sessionEndWndProc fires only sessionEndSignal() (non-blocking) then returns 1; no I/O (REVIEWS HIGH fix)"
  - "PostMessage(WM_QUIT) to HWND for pump shutdown: PostQuitMessage posts to current thread not pump goroutine's thread — switched to PostMessage to correct thread"
  - "Injectable emitter for tests: newWatcherBridgeWithEmitter avoids Wails runtime panics with background context"
  - "Drain unified via runBoundedDrain: both session-end and normal shutdown paths cancel same context; watcher.Stop + bridge.Close called exactly once from drain func"
  - "systray.Run on LockOSThread'd goroutine (not RunWithExternalLoop): Win32 dispatches tray click messages to the thread that owns the window's message queue. RunWithExternalLoop's start() spawns a fresh goroutine for pump on a different OS thread — right-click messages were never dispatched."
  - "App-tracked visibility instead of wruntime.WindowIsNormal: IsNormal returns !IsMaximised && !IsMinimised && !IsFullScreen — it does NOT check visibility. After WindowHide, IsNormal stays true."
  - "HideWindowOnClose dropped in favour of OnBeforeClose-driven hide: Wails' HideWindowOnClose short-circuits the X button to f.WindowHide() without invoking OnBeforeClose. That bypassed visibility tracking AND left no hook to differentiate X-button (hide) from tray Quit menu (terminate). Unifying through OnBeforeClose + intentionalQuit gate solves both."

requirements-completed: [SHELL-04, SHELL-05, SHELL-06, QUAL-04]

# Metrics
duration: 180min
completed: 2026-04-13
---

# Phase 07 Plan 03: Windows Lifecycle (Single-instance, Session-end, Watcher fold-in) Summary

**Added single-instance mutex with named-event raise transport, WM_QUERYENDSESSION handler with prompt-return WndProc and bounded async drain, and mapi.EmailWatcher folded into Wails app via 1-slot coalescing bridge; GetQueue now returns live snapshot. End-of-plan human-verify checkpoint surfaced three real lifecycle bugs (tray pump thread affinity, single-instance detection, tray toggle + Quit menu wiring) — all fixed atomically; user approved all 10 verification steps.**

## Performance

- **Duration:** ~3 hours total (90 min initial + ~90 min across three fix iterations)
- **Started:** 2026-04-13
- **Completed:** 2026-04-13 (user approved Task 4 checkpoint)
- **Tasks:** 3 auto-executed + 1 human-verify checkpoint passed + 3 bug-fix iterations
- **Files:** 8 created, 4 modified
- **Test count:** 23 unit tests (8 single-instance inc. Bug C regression, 7 sessionend, 7 watcher bridge, 1 logging-path)

## Task Commits

1. **Task 1: Single-instance mutex + named-event raise transport** — `7951b3e`
2. **Task 2: WM_QUERYENDSESSION handler + watcher bridge type** — `d6fd798`
3. **Task 3: Watcher fold-in + GetQueue live snapshot** — `53609a4`
4. **Build support: go.mod direct dep + regenerated wailsjs bindings** — `9322616`
5. **SUMMARY.md (provisional)** — `a8c983f`
6. **Fix: tray menu — pump messages on window-creation thread** — `e8b95da`
7. **Fix: single-instance — canonical err from CreateMutex (Bug C)** — `0355bb4`
8. **Fix: tray toggle + Quit menu — visibility tracking + intentionalQuit gate (Bugs A+B)** — `5cf08e2`

## Accomplishments

- `singleinstance.go`: `Local\go-mapi-singleton-v3` mutex with `errors.Is(err, windows.ERROR_ALREADY_EXISTS)` canonical detection; `Local\go-mapi-raise-v3` named event as primary raise transport; `waitForRaiseSignal` dispatcher goroutine in `App.startup`
- `sessionend.go`: hidden message-only HWND; `sessionEndWndProc` returns 1 (TRUE) immediately and fires only a non-blocking signal; `runBoundedDrain` with 2-second `context.WithTimeout` + `os.Exit(0)` fallback
- `watcher_bridge.go`: 1-slot buffered channel with drop-policy; dispatcher goroutine calls `EventsEmit("queue-update")` off watcher goroutine path; `sync.Once` idempotent `Close()`
- `logging.go`: RFC3339 `[INFO]`/`[ERROR]` file logger at `%APPDATA%\go-mapi\app.log`; no email content logged (T-07-22 mitigated)
- `paths.go`: `watcherDir()` mirrors native-host `defaultWatchDir()` + `GOMAPI_WATCH_DIR` override
- `app.go`: `GetQueue()` returns live `watcher.Snapshot()` replacing Plan 02 nil stub; visibility tracking + intentionalQuit quit-gate added
- `tray.go`: dedicated LockOSThread'd goroutine runs `systray.Run` (fixes right-click menu dispatch)
- `App.svelte`: `EventsOn('queue-error')` listener wired
- All 10 human-verify steps passed (tray startup/tooltip/menu, show via menu, left-click toggle, close-to-tray, single-instance + raise, live queue update, logoff clean exit, Quit via menu)

## Mutex and Named Event Confirmation

| Constant | Value | Scope |
|----------|-------|-------|
| `mutexName` | `Local\go-mapi-singleton-v3` | Per-session (RDS isolated) |
| `raiseEventName` | `Local\go-mapi-raise-v3` | Per-session (RDS isolated) |

Both use `Local\` scope — each RDS user session owns exactly one instance. `Global\` scope was explicitly NOT used.

## ERROR_ALREADY_EXISTS Detection Confirmation (post-Bug C fix)

```go
handle, createErr := windows.CreateMutex(nil, false, name)
if handle == 0 {
    return false, fmt.Errorf("CreateMutex failed: %w", createErr)
}
if errors.Is(createErr, windows.ERROR_ALREADY_EXISTS) {
    _ = windows.CloseHandle(handle) // close duplicate handle
    // signal first instance via named event, return raised=true
    return true, nil
}
```

Uses the `err` return from `windows.CreateMutex` directly. The `x/sys/windows` `//sys` directive `[failretval == 0 || e1 == ERROR_ALREADY_EXISTS]` surfaces the errno on the same syscall, making this race-free. The initial GetLastError-based approach (from REVIEWS HIGH) was empirically wrong in Go — confirmed by user repro of multiple coexisting instances.

## Raise Transport Confirmation

Primary transport: `CreateEvent` → `OpenEvent` + `SetEvent`. `FindWindowW` does NOT appear in any production code path (only in comments explaining why it was eliminated). Confirmed end-to-end: second launch signals first instance's named event, first instance's `waitForRaiseSignal` dispatcher wakes and calls `showWindow`; second instance exits via `os.Exit(0)`.

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

This ensures Windows logoff is never blocked past 2 seconds regardless of watcher state. Confirmed by human-verify step 9 (logoff clean exit).

## watcher.Stop + bridge.Close Idempotency Confirmation

- `watcher.Stop()`: `sync.Once` from Plan 01 Test 7 — proven idempotent
- `bridge.Close()`: `sync.Once` guards `close(b.done)` — calling twice does not panic (Task 3 Test 5 `TestBridgeCloseIdempotent`)
- Both wrapped in `if != nil` guards in `runBoundedDrain` drain function

## EventsEmit Audit

| Location | Goroutine | Event |
|----------|-----------|-------|
| `watcher_bridge.go:29` inside `dispatch()` | dispatcher goroutine (NOT watcher goroutine) | `queue-update` |
| `app.go` watcher startup error path | startup goroutine | `queue-error` |
| `app.go` watcher start goroutine error path | watcher start goroutine | `queue-error` |

`EventsEmit` is never called from `OnQueueChanged` or any watcher-held-lock path. Pitfall §5 compliance confirmed.

## Tray Thread-Affinity Model (post-e8b95da)

`systray.Run` runs inside `go func() { runtime.LockOSThread(); systray.Run(...) }()`. The window and its message pump share one locked OS thread. WM_LBUTTONUP/WM_RBUTTONUP reach `wt.wndProc`, which calls `systrayLeftClick`/`systrayRightClick`. Left-click fires `SetOnTapped` callback (`toggleWindow`); right-click falls through to `wt.showMenu` (`TrackPopupMenu`). Using `RunWithExternalLoop` here was wrong — its `start()` spawns a fresh goroutine for the pump on a different OS thread, so tray clicks were never dispatched.

## Visibility + Quit Gate Model (post-5cf08e2)

```
┌─ X button ────────┐
│ Wails OnClose     │──> OnBeforeClose (intentionalQuit=false)
│ (no              │       └─> WindowHide + setVisible(false) + return true (prevent)
│  HideWindowOnClose)│
└───────────────────┘
┌─ Left-click tray ─┐
│ SetOnTapped       │──> toggleWindow
│  callback         │       └─> if isVisible() → hideWindow, else → showWindow
└───────────────────┘
┌─ Tray Show menu ──┐──> a.showWindow()
└───────────────────┘       └─> WindowShow + WindowUnminimise + setVisible(true)
┌─ Tray Quit menu ──┐──> a.requestQuit()
└───────────────────┘       ├─> intentionalQuit.Store(true)
                            └─> wruntime.Quit → OnBeforeClose returns false → Wails terminates
```

Visibility is authoritative inside the App struct because Wails exposes no `WindowIsVisible` runtime API and `WindowIsNormal` (!Maximised && !Minimised && !Fullscreen) is not a visibility proxy.

## Cross-Module Test Results

```
ok  github.com/marcfargas/go-mapi/native-host
ok  github.com/marcfargas/go-mapi/app
```

Both modules pass. QUAL-04 met. (`-race` not supported on windows/arm64 dev machine — same constraint as Plan 01; CI on non-ARM64 host is the `-race` verification environment.)

## Build Verification

`wails build -clean` in `src/app/` produced `src/app/build/bin/go-mapi.exe` successfully. Final rebuild after Bugs A/B/C fixes: 4.2s.

## Known Stubs

None — all data flows are wired:
- `GetQueue()` returns `a.watcher.Snapshot()` (live watcher state)
- `EventsEmit("queue-update")` fires on every queue change
- `EventsOn("queue-error")` wired in Svelte to show error state
- Tray Show/Quit menu clicks dispatched correctly on locked OS thread
- Tray toggle tracks own visibility; Quit menu bypasses hide-to-tray via intentionalQuit flag

## Human-Verify Checkpoint (Task 4) — APPROVED

User re-tested `src/app/build/bin/go-mapi.exe` after commits `e8b95da` + `0355bb4` + `5cf08e2`:

| # | Step | Result |
|---|------|--------|
| 1 | Startup, no flash | PASS |
| 2 | Tray tooltip | PASS |
| 3 | Right-click menu (Show + Quit) | PASS |
| 4 | Show via menu — 480×600 + empty-state card | PASS |
| 5 | Left-click toggle (hide AND show — Bug A regression) | PASS |
| 6 | Close to tray (X-button hide-to-tray) | PASS |
| 7 | Single-instance + raise (Bug C regression) | PASS |
| 8 | Live queue update from fixture drop | PASS |
| 9 | Logoff clean exit (< 5s, no half-written JSON) | PASS |
| 10 | Quit via tray menu (Bug B regression) | PASS |

All 10 steps pass. Plan 04 (RAM measurement) is unblocked.

## Deviations from Plan

### Auto-fixed Issues (discovered during task execution)

**1. [Rule 3 - Blocking] `PostQuitMessage` posts to wrong thread**
- **Found during:** Task 2 sessionend_test — `TestRegisterSessionEndHandlerReturnsCancel` timed out (cancel() hung)
- **Issue:** `procPostQuitMsg.Call(0)` posts `WM_QUIT` to the CALLING thread's message queue, not the goroutine running the message pump (different OS thread). The pump never received WM_QUIT and blocked indefinitely on `GetMessage`.
- **Fix:** Replaced `PostQuitMessage` with `PostMessage(hwnd, WM_QUIT, 0, 0)` which posts to the thread owning the HWND (the pump goroutine). Added 500ms timeout in cancel to avoid blocking shutdown if pump doesn't respond.
- **Files modified:** `src/app/sessionend.go`
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

### Bugs Surfaced by Human-Verify Checkpoint (Task 4)

**4. [Rule 1 - Bug] Tray right-click menu never appeared**
- **Found during:** Task 4 checkpoint Step 3 — tooltip + icon worked but right-click produced no menu
- **Issue:** `fyne.io/systray.RunWithExternalLoop` creates the tray's hidden window on the caller's goroutine, but its `start()` spawns a fresh goroutine for the Win32 message pump. Goroutines float across OS threads; `GetMessage` reads from the calling thread's queue, not the window-owning thread's queue. Result: WM_RBUTTONUP/WM_LBUTTONUP posted to the tray window's thread were never dispatched → no menu, no tap handler. Tooltip worked because `Shell_NotifyIcon` doesn't require message pumping.
- **Fix:** Switched to `systray.Run` on a single dedicated goroutine with `runtime.LockOSThread()`. `Register` + `nativeLoop` share one pinned thread. `trayEnd` is now `systray.Quit()`.
- **Files modified:** `src/app/tray.go`
- **Commit:** `e8b95da`

**5. [Rule 1 - Bug C] Multiple instances coexisted (single-instance mutex didn't block second launch)**
- **Found during:** Task 4 checkpoint Step 7 — second `go-mapi.exe` stayed running and the first window wasn't raised
- **Issue:** `acquireSingleInstance` called `windows.GetLastError()` AFTER `windows.CreateMutex` to detect `ERROR_ALREADY_EXISTS`. In Go this is unreliable — the runtime may run other goroutines / syscalls on the OS thread between the two calls and clobber per-thread last-error. `x/sys/windows.CreateMutex` already surfaces `ERROR_ALREADY_EXISTS` via the `err` return (`//sys` directive `[failretval == 0 || e1 == ERROR_ALREADY_EXISTS]`). The initial implementation got `lastErr == 0`, treated the second instance as the first, kept the handle, and proceeded into `wails.Run`.
- **Fix:** Switched to `errors.Is(createErr, windows.ERROR_ALREADY_EXISTS)` on the wrapper's return. Same fix applied to `CreateEvent` (stale event from a previously-killed first instance is now adopted). Added `os.Exit(0)` on the raised path for fastest exit. Added `TestSecondAcquireDetectsExistingInstance` — a regression test that exercises the actual second-acquire-while-first-holds path on the same kernel mutex object.
- **Files modified:** `src/app/singleinstance.go`, `src/app/singleinstance_test.go`, `src/app/main.go`
- **Commit:** `0355bb4`
- **Retrospective:** REVIEWS HIGH flagged `CreateMutex` semantics as needing `GetLastError`. That advice applied to a raw cgo `CreateMutexW` call — `x/sys/windows.CreateMutex` already does the GetLastError dance internally. The fix follows `x/sys` canonical usage.

**6. [Rule 1 - Bug A] Left-click tray toggle was one-way (hide worked, show didn't)**
- **Found during:** Task 4 checkpoint Step 5
- **Issue:** `toggleWindow` used `wruntime.WindowIsNormal` to decide hide vs show. On Windows, `IsNormal` returns `!IsMaximised && !IsMinimised && !IsFullScreen` — it does NOT check visibility. After `WindowHide`, the window is still "normal" (just invisible), so a second left-click hid again instead of showing.
- **Fix:** App now tracks visibility itself via `visibilityMu` + `visible bool`. `setVisible` / `isVisible` accessors. `toggleWindow` consults `a.isVisible()`. `showWindow` / `hideWindow` update the flag.
- **Files modified:** `src/app/app.go`, `src/app/tray.go`
- **Commit:** `5cf08e2`

**7. [Rule 1 - Bug B] Right-click → Quit menu did nothing**
- **Found during:** Task 4 checkpoint Step 10
- **Issue:** `beforeClose` unconditionally returned `true` (prevent close). Wails' frontend `Quit()` consults `OnBeforeClose` and aborts on `true`, so `wruntime.Quit` from the tray Quit menu was silently cancelled. The X button worked because `HideWindowOnClose: true` short-circuits to `f.WindowHide()` without calling `OnBeforeClose` at all — masking the bug for the X path.
- **Fix:** Dropped `HideWindowOnClose` (X-button now reaches `OnBeforeClose`, which hides + updates visibility). Added `intentionalQuit atomic.Bool` on App. Tray Quit menu calls `a.requestQuit()` which sets the flag THEN calls `wruntime.Quit`. `beforeClose` checks the flag: true → return false (allow terminate); false → hide to tray.
- **Files modified:** `src/app/app.go`, `src/app/main.go`, `src/app/tray.go`
- **Commit:** `5cf08e2` (same commit as Bug A — joint lifecycle fix)

---

**Total deviations:** 7 (all auto-fixed Rules 1+3). Deviations 1–3 surfaced during task TDD; deviations 4–7 surfaced during Task 4 human-verify checkpoint. Checkpoint ultimately approved after three fix iterations.

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

## Follow-ups

**Test coverage for tray/window/lifecycle behaviour — flagged by user after Task 4 checkpoint.**

Three real bugs (`e8b95da`, `0355bb4`, `5cf08e2`) were caught only by manual human-verify testing. Each would have been caught by a targeted automated test. Phase 8 should not start these workstreams without a test story in place.

### Bugs that automated coverage would have caught

1. **`e8b95da` — Tray right-click menu / thread affinity.** A test that actually posts `WM_RBUTTONUP` to the tray window's HWND and verifies the menu-popup code path runs (or: that `wt.wndProc` receives the message within a deadline). Would detect any future regression where systray and Wails fight for the Win32 message pump. Candidate harness: in-process Win32 API driver (PostMessage + poll) OR external UI driver (WinAppDriver / pywinauto).

2. **`0355bb4` — Single-instance (Bug C).** We already shipped `TestSecondAcquireDetectsExistingInstance` as part of the fix. Going further: a subprocess integration test that spawns two `go-mapi.exe` processes back-to-back and asserts (a) the second exits within 1s, (b) the first is still running, (c) the first's named event was signalled. This test exists as a commented-out skeleton in `singleinstance_test.go`'s Test 8 pattern; Phase 8 should materialise it using `os/exec` and the already-built binary.

3. **`5cf08e2` — Tray toggle (Bug A) + Quit menu (Bug B).** Tests that drive `a.toggleWindow()` in hide/show/hide/show sequences and assert `a.isVisible()` tracks correctly after each call. Plus a test that simulates the tray Quit path: set `intentionalQuit`, call `beforeClose`, assert it returns `false` (allows terminate); without setting the flag, assert it returns `true` (prevents).

### Investigate before Phase 8

**Pick a Wails testing story.** Options seen in the research corpus:
- **WinAppDriver** — Microsoft's Selenium-like driver for Windows UIA (WinUI, Win32, WPF). We already use Playwright for the Chrome-extension E2E; WinAppDriver would be the natural analogue for the Wails shell. Pros: real user-facing coverage, same model as extension E2E. Cons: brittle on WebView2 internals; requires admin setup.
- **pywinauto** — Python library that drives Windows controls via UIA or Win32. Pros: fast scripting, no admin. Cons: different test language, weaker WebView2 story.
- **Mockable `wruntime` shims** — extract a minimal interface (`WindowShow`, `WindowHide`, `WindowIsNormal`, `Quit`, `EventsEmit`) that `app.go` depends on, injected at construction. Production wires the real `wruntime` package; tests wire a fake. This directly addresses Bugs A and B (toggle + Quit gate) and the coalescing-test Wails-context panic that already surfaced in deviation #3. Low cost; very high ROI for the visibility/lifecycle code that just had three bugs.
- **Go + Win32 direct testing** — for things like `e8b95da` (tray menu dispatch) where no test framework helps, write Win32-aware integration tests (`PostMessage` to the tray HWND, assert handler fires). Requires `runtime.LockOSThread`, careful message-pump setup.

**Recommendation:** ship the `wruntime` shim (cheapest, highest coverage of the three bugs) + resurrect the subprocess single-instance test in Phase 8. Defer WinAppDriver/pywinauto until the Wails shell has more surface area (Phase 9 onwards when Phase 9 adds queue actions and toast notifications).

## Self-Check: PASSED

**Files verified:**
- FOUND: `src/app/singleinstance.go`
- FOUND: `src/app/singleinstance_test.go` (now 9 tests — added Bug C regression)
- FOUND: `src/app/sessionend.go`
- FOUND: `src/app/sessionend_test.go`
- FOUND: `src/app/watcher_bridge.go`
- FOUND: `src/app/watcher_bridge_test.go`
- FOUND: `src/app/logging.go`
- FOUND: `src/app/paths.go`
- FOUND: `src/app/app.go` (extended + lifecycle rewire)
- FOUND: `src/app/main.go` (updated — os.Exit second-instance, no HideWindowOnClose)
- FOUND: `src/app/tray.go` (updated — LockOSThread pump, visibility tracking, requestQuit)
- FOUND: `src/app/frontend/src/App.svelte` (updated)

**Commits verified:**
- `7951b3e` — feat(07-03): single-instance mutex + named-event raise transport (Task 1)
- `d6fd798` — feat(07-03): WM_QUERYENDSESSION handler + watcher bridge type (Task 2)
- `53609a4` — feat(07-03): watcher fold-in + GetQueue live snapshot (Task 3)
- `9322616` — chore(07-03): update go.mod direct dep + regenerate wailsjs bindings
- `a8c983f` — docs(07-03): provisional SUMMARY before Task 4 checkpoint
- `e8b95da` — fix(07-03): tray menu — pump messages on window-creation thread
- `0355bb4` — fix(07-03): single-instance — canonical err from CreateMutex (Bug C)
- `5cf08e2` — fix(07-03): tray toggle + Quit menu — visibility + intentionalQuit (Bugs A+B)

**Build verified:** `wails build -clean` → `src/app/build/bin/go-mapi.exe` in 4.2s ✓

**Tests verified:**
- `src/native-host`: ok (0 failures)
- `src/app`: ok (0 failures, including `TestSecondAcquireDetectsExistingInstance` Bug C regression)

**Checkpoint:** Task 4 (human-verify) APPROVED by user — all 10 steps pass. Plan 04 (RAM measurement) is unblocked.
