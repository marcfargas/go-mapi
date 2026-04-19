---
phase: 09-queue-automode-toasts
plan: "05"
subsystem: tray-icon-pause-menu
tags: [tray, icons, pause-menu, tooltip, asset, systray-hwnd-affinity, coalescing]
dependency_graph:
  requires:
    - phase: 09-03
      provides: isPaused/SetPaused/getMode helpers + SetAfterDispatch hook
    - phase: 09-04
      provides: PauseWatching/ResumeWatching/GetPausedState Wails bindings
  provides:
    - tray-has-queue.ico (amber dot overlay, 48x48+32x32+16x16 frames)
    - computeTrayVisual pure helper (D-16 icon priority + D-17 tooltip format)
    - trayState struct (Mode/Paused/SignedIn/ErrorMsg/Count)
    - trayRefreshCh 1-slot signal channel (T-9-10 HWND affinity fix, T-9-11 coalescing)
    - refreshTrayVisual (runs on tray goroutine only)
    - Pause watching/Resume watching tray menu item (SHELL-02 completion)
    - setLastError/getLastError/signalTrayRefresh helpers
  affects:
    - 09-06 (toast notifications — tray state changes after pause/mode/queue events)
    - 09-07 (queue row UI — mode toggle sends signalTrayRefresh via setMode)
    - 09-08 (tray menu — Pause menu item is here)
tech_stack:
  added: []
  patterns:
    - pure-function visual state computer (computeTrayVisual — testable without systray)
    - 1-slot drop-if-full coalesce channel (trayRefreshCh, mirrors watcher_bridge pending)
    - idempotent error signal (setLastError only signals on value change)
    - HWND-affinity isolation (all systray.* calls confined to tray goroutine via channel)
key_files:
  created:
    - src/app/assets/tray/tray-has-queue.ico
    - src/app/assets/tray/sources/tray-has-queue.svg
    - src/app/tray_test.go
  modified:
    - src/app/tray.go
    - src/app/app.go
    - src/app/auth.go
key-decisions:
  - "computeTrayVisual: paused icon stays idle (not a distinct amber variant) — D-16 explicitly says paused/signed-out are tooltip-only; only error and has-queue get distinct icons"
  - "trayRefreshCh 1-slot drop-if-full (not 0-slot block): bursts of 50 queue-updates coalesce to 1 tray refresh; snapshot re-read on each wake prevents state staleness"
  - "setLastError idempotent signalling: second call with same message does NOT re-signal (tested by TestSetLastError_SignalsRefreshOnlyOnChange); prevents wake storms on persistent errors"
  - "auth.go bootstrapAuth async goroutine: added signalTrayRefresh() after emitAuthChanged so tray reflects SignedIn=true after userinfo fetch settles"
  - "ICO format matches existing assets: 3-frame (48x48+32x32+16x16) via ImageMagick auto-resize, amber #E8A600 circle at (38,38) r=6 on 48x48 viewbox"
requirements_closed: [SHELL-02, SHELL-07]
duration: "~40 minutes"
completed: "2026-04-19T13:45:00Z"
---

# Phase 9 Plan 05: Tray Has-Queue Icon + Pause Menu + computeTrayVisual Summary

**Tray amber-dot icon (SHELL-07), Pause watching menu item (SHELL-02), pure computeTrayVisual helper covering all D-16/D-17 priority combinations, and trayRefreshCh channel routing all systray.* calls through the tray goroutine (T-9-10 HWND affinity fix).**

## Performance

- **Duration:** ~40 minutes
- **Started:** 2026-04-19T13:05:00Z
- **Completed:** 2026-04-19T13:45:00Z
- **Tasks:** 3 (code tasks) + 1 (checkpoint — awaiting human QA)
- **Files modified:** 6

## Accomplishments

- Created `tray-has-queue.ico` with amber `#E8A600` dot bottom-right on the existing envelope glyph. Three-frame ICO (48×48, 32×32, 16×16) generated via ImageMagick `auto-resize`. Committed alongside SVG source `tray-has-queue.svg` following the existing `sources/` convention.
- Defined `trayState` struct and `computeTrayVisual` pure function in `tray.go`. Pure = no systray calls, no global reads — fully testable from any goroutine. Covers all D-16 icon priority combinations and D-17 tooltip format combinations (8 subtests, all passing at count 5).
- Added `trayHasQueueIcon` embed via `//go:embed assets/tray/tray-has-queue.ico` (matching the existing idle/error embed pattern).
- Added `trayRefreshCh chan struct{}` (1-slot, initialized in `NewApp`) to `App`. All app goroutines that change tray-relevant state call `signalTrayRefresh()` (non-blocking drop-if-full) instead of touching `systray.*` directly. The tray goroutine's select loop drains the channel and calls `refreshTrayVisual()` on its LockOSThread context (T-9-10 mitigation).
- Added `setLastError`/`getLastError` helpers (mutex-guarded `lastErrorMsg` field). `setLastError` only signals on value change (idempotent — T-9-11 wake-storm prevention).
- Refactored `SetTrayError` and `SetTrayIdle` to route through `setLastError` → `signalTrayRefresh` instead of calling `systray.SetIcon`/`systray.SetTooltip` directly. All existing call sites in auth.go compile unchanged — their existing `SetTrayError`/`SetTrayIdle` calls are now HWND-safe.
- Added `Pause watching` menu item in `onTrayReady` between Show and Quit. Click handler reads current `isPaused()` state, toggles via `PauseWatching()`/`ResumeWatching()`, and flips the menu label to `Resume watching`/`Pause watching`. Tooltip: `Silences toasts and auto-draft; queue still collecting` (UI-SPEC copywriting).
- Wired `signalTrayRefresh()` into: `SetPaused` (on change), `setMode` (on save), `bridge.SetAfterDispatch` (on every queue-update), and the bootstrapAuth async goroutine (after userinfo fetch settles).
- `go vet ./...` clean. Full `src/app` test suite passes (`go test -count 1 -timeout 120s ./...`).

## Task Commits

| # | Name | Commit | Files |
|---|------|--------|-------|
| 1 | Add tray-has-queue.ico with amber dot overlay | 8f36e8f | src/app/assets/tray/tray-has-queue.ico, sources/tray-has-queue.svg |
| 2 (RED) | Add failing tests for computeTrayVisual + tray refresh coalescing | df377f7 | src/app/tray_test.go |
| 2+3 (GREEN) | computeTrayVisual helper + trayState + trayRefreshCh + Pause menu | 8184351 | src/app/tray.go, src/app/app.go, src/app/auth.go |

## Files Created/Modified

- `src/app/assets/tray/tray-has-queue.ico` — New 3-frame ICO (48×48, 32×32, 16×16), amber `#E8A600` circle overlay
- `src/app/assets/tray/sources/tray-has-queue.svg` — SVG source (48×48 viewbox, amber circle at cx=38 cy=38 r=6)
- `src/app/tray.go` — Added: `trayHasQueueIcon` embed; `trayState` struct; `computeTrayVisual`; `refreshTrayVisual`; Pause menu item + click handler; refactored `SetTrayError`/`SetTrayIdle` as thin wrappers over `setLastError`
- `src/app/app.go` — Added: `errorMsgMu`/`lastErrorMsg` fields; `trayRefreshCh` field + init in `NewApp`; `setLastError`/`getLastError`/`signalTrayRefresh` helpers; `signalTrayRefresh()` calls in `SetPaused`, `setMode`, `bridge.SetAfterDispatch`
- `src/app/auth.go` — Added: `signalTrayRefresh()` call in bootstrapAuth async goroutine after `emitAuthChanged`
- `src/app/tray_test.go` — New: `TestComputeTrayVisual` (8 subtests), `TestSignalTrayRefresh_Coalesces`, `TestSetLastError_SignalsRefreshOnlyOnChange`

## Decisions Made

- `computeTrayVisual`: paused state keeps the idle icon (not a distinct variant). D-16 explicitly says paused/signed-out are tooltip-only. This keeps the icon count at 3 (idle/has-queue/error).
- `trayRefreshCh` uses 1-slot buffered channel with drop-if-full (not a 0-slot blocking channel). This coalesces bursts (50 queue-updates → 1 tray refresh) while keeping `signalTrayRefresh()` non-blocking from hot watcher paths (mirrors the existing `pending` channel in `watcher_bridge.go`).
- `setLastError` is idempotent: signalling only fires when the message actually changes. Prevents wake storms when watcher error path fires repeatedly on the same condition.
- ICO created with `magick convert ... -define icon:auto-resize=48,32,16` matching the existing `tray-idle.ico`/`tray-error.ico` generation approach documented in SVG comment headers.
- `signalTrayRefresh` added to bootstrapAuth goroutine after `emitAuthChanged` because `refreshTrayVisual` reads `auth.Status().Authenticated` — the tray needs to reflect signed-in state after userinfo fetch completes, not just after the error is cleared.

## Deviations from Plan

### Auto-fixed Issues

None — plan executed exactly as written. The only structural deviation is that Tasks 2 and 3 were implemented in a single GREEN commit (`8184351`) since the tray goroutine wiring, Pause menu, and `computeTrayVisual` helper are tightly coupled: separating them would have required a non-compiling intermediate state.

### Notes on existing test environment

The worktree lacks `frontend/dist` (the Wails frontend build output). A placeholder `frontend/dist/index.html` was created to satisfy the `//go:embed all:frontend/dist` directive in `main.go` so `go test ./...` compiles. This is consistent with how the existing test suite works in CI (the embed glob requires the directory to exist but tests do not exercise the embedded assets). The placeholder file is NOT committed (it is gitignored or otherwise omitted from the task commits).

## Manual QA Checklist

The following checks require a real Windows desktop (Windows 10/11, RDS session preferred). Build and launch:

```powershell
cd C:\dev\go-mapi\src\app
wails build -clean
.\build\bin\go-mapi.exe
```

**Check 1: Empty queue, signed in, Manual mode**
- Hover tray icon → tooltip must read exactly: `go-mapi — Manual — 0 pending`
- Icon must show idle variant (no amber dot)

**Check 2: Empty queue, signed in, Auto-draft mode**
- Edit `%APPDATA%\go-mapi\settings.json` → `{"mode":"auto-draft"}` and restart, OR use the mode toggle in the UI (if Plan 09 has landed)
- Hover → tooltip must read: `go-mapi — Auto-draft — 0 pending`

**Check 3: Non-empty queue (amber dot visible)**
- Drop a valid email JSON into `%TEMP%\go-mapi\` (copy from `internal/mapi/tests/protocol-fixtures/`)
- Within ~1 second the tray icon must swap to the amber-dot variant (`tray-has-queue.ico`)
- Hover → tooltip: `go-mapi — Manual — 1 pending` (or Auto-draft)

**Check 4: Pause menu — label flip + tooltip change**
- Right-click tray → menu shows `Pause watching`
- Click `Pause watching`
- Menu label becomes `Resume watching`
- Hover tray icon → tooltip: `go-mapi — Paused — 1 pending`
- Icon reverts to idle (amber dot disappears even though queue has email)
- Right-click → `Resume watching` → click
- Menu label flips back to `Pause watching`
- Tooltip returns to previous mode label (e.g., `go-mapi — Manual — 1 pending`)
- Amber dot reappears (queue still present)

**Check 5: Signed-out state**
- Sign out via the UI (Sign out button in SignedInHeader)
- Hover → tooltip: `go-mapi — Signed out — N pending`
- Icon: idle variant (has-queue requires signed-in per D-16)

**Check 6: Watcher error (optional — hard to reproduce)**
- Force `watcher stopped` by deleting `%TEMP%\go-mapi\` while the app is running
- Tooltip should read: `go-mapi — watcher stopped` and icon should flip to error variant
- Skip if reproduction is too fragile; covered by Phase 7 verification

**Check 7: RDS validation (optional but preferred)**
- Repeat checks 1–5 inside an RDS session (mstsc → Windows Server test VM)
- Confirm multi-frame ICO renders at 96 DPI and 150 DPI without blurring
- Confirm Pause state is per-session (each RDS user's process has independent state)

**Resume signal:** Reply `approved` if checks 1–5 pass. Describe any failing check with observed vs expected behavior.

### Status (2026-04-19): DEFERRED

Manual QA intentionally deferred per user decision during Phase 9 execution. See `.planning/todos/pending/2026-04-19-automate-tray-visual-qa-windows-sandbox.md` for the automation plan that will replace this manual checklist (Windows Sandbox + FlaUI / UI Automation). The checks above remain valid until that harness lands.

Acceptance: code is approved as-written. Manual visual QA reclassified as outstanding UAT — will surface in `/gsd-progress` and `/gsd-audit-uat` until closed by the automation todo or a future manual pass.

## Known Stubs

None. All behavior is fully implemented. The `tray-has-queue.ico` is a real asset, not a placeholder. `computeTrayVisual` is a complete pure function tested across all combinations.

## Threat Flags

No new network endpoints, auth paths, or schema changes introduced. The tray channel (`trayRefreshCh`) is an in-process Go channel — no external trust boundary. The `setLastError` mutex-guarded field does not persist to disk or emit to the frontend.

## Self-Check

Files exist:
- `src/app/assets/tray/tray-has-queue.ico` — FOUND (15086 bytes, MS Windows icon resource, 3 frames)
- `src/app/assets/tray/sources/tray-has-queue.svg` — FOUND
- `src/app/tray_test.go` — FOUND
- `src/app/tray.go` — FOUND (modified)
- `src/app/app.go` — FOUND (modified)
- `src/app/auth.go` — FOUND (modified)

Commits exist:
- `8f36e8f`: feat(09-05): add tray-has-queue.ico with amber dot overlay
- `df377f7`: test(09-05): add failing tests for computeTrayVisual + tray refresh coalescing
- `8184351`: feat(09-05): computeTrayVisual helper + trayState + trayRefreshCh + tests green

## Self-Check: PASSED
