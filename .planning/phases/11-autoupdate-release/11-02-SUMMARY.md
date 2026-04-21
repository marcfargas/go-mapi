---
phase: 11-autoupdate-release
plan: 02
subsystem: tray
tags: [tray, notifications, systray, updates, toast, wails]

# Dependency graph
requires:
  - phase: 11-autoupdate-release
    plan: 01
    provides: App.GetUpdateState / App.CheckForUpdatesNow / update-state-changed event / cached UpdateState snapshot; 11-02 consumes these as the sole source of update metadata.
  - phase: 09-queue-automode-toasts
    provides: toast subsystem (initToasts, shimPushWithTagGroup, AUMID/activator/icon pipeline) and the tray signal/render split (trayRefreshCh, signalTrayRefresh); 11-02 piggybacks on both.
provides:
  - trayState.UpdateAvailable and computeTrayVisual icon/tooltip transition for the update-available visual (REL-04 visual anchor)
  - tray Version / Last checked status rows + "Check for updates" checkbox + "Check for updates now" action + "Download update" (hidden when no update)
  - App.setUpdateChecksEnabled (and Wails binding SetUpdateChecksEnabled) writing through the single-writer saveSettings path (D-05)
  - App.runTrayManualUpdateCheck (D-06 tray wrapper around CheckForUpdatesNow; failure-silent per D-04)
  - App.snapshotUpdateAvailable atomic read for tray rendering
  - App.setUpdateStateObserver in-process observer slot (separate from updateStateEmitter) + tray refresh signal from applyUpdateCheckResult
  - formatUpdateCurrentVersionLabel / formatUpdateLastCheckedLabel pure helpers for D-07 tray rows
  - openUpdateReleasePage helper (REL-04 + D-03 — opens release page via browser, never launches installer)
  - src/app/update_notifications.go — buildUpdateNotificationPlan + updateNotificationTracker + wireUpdateNotifications + pushUpdateNotification; tracker fires only on flip-to-available or newer LatestVersion
  - handleToastAction "open-update" case routing to openUpdateReleasePage
  - assets/tray/tray-update.ico (update-available icon variant)
affects: [11-03 frontend banner/panel consumes update-state-changed event + SetUpdateChecksEnabled binding + InstallerURL exposure]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pure-helper tray formatting (formatUpdate*Label) testable without a live systray host"
    - "In-process observer fan-out separate from Wails EventsEmit (updateStateObserver ≠ updateStateEmitter) so tray/notification subscribers never race the frontend wiring"
    - "Dedup-by-version notification tracker: flip-to-available OR newer LatestVersion fires; repeated same-version observations are silent"
    - "D-03 structural guard: reflect across updateNotificationPlan field names in tests to reject any future exec/install/launch/replace/quit/staged field additions"
    - "Tray status rows refreshed in place (SetTitle) on every trayRefreshCh wake — no systray menu rebuild, thread affinity preserved"
    - "openUpdateReleasePage fallback to repo /releases landing page when LatestReleaseURL is empty, NEVER the stable installer URL (reserved for 11-03 in-app panel)"

key-files:
  created:
    - src/app/tray_update.go
    - src/app/tray_update_test.go
    - src/app/update_notifications.go
    - src/app/update_notifications_test.go
    - src/app/assets/tray/tray-update.ico
  modified:
    - src/app/tray.go
    - src/app/app.go

key-decisions:
  - "Tray Download action points at LatestReleaseURL (falls back to repo /releases landing page), NEVER at installerDownloadURL — that direct installer link is reserved for the in-app update panel per D-02 / phase scope split"
  - "Update-available visual is an explicit tray state integrated into computeTrayVisual (trayUpdateIcon when no queue, tooltip marker ' • Update available' always when set) — satisfies 'explicit tray visual state' per plan task 1 action paragraph"
  - "tray-update.ico ships as a bitwise copy of tray-has-queue.ico for v3.0 — distinct artwork is deferred because the tooltip marker already carries the semantic signal and the icon priority (error > has-queue > update > idle) remains testably correct"
  - "Observer split (updateStateObserver added alongside updateStateEmitter) keeps the Wails event emission path and the in-process notification path independent — neither can hijack the other, and tests for each target exactly one slot"
  - "Notification tracker de-dupes by LatestVersion so the user sees one toast per distinct release, not one per 24h cadence tick"
  - "Plan-local openUpdateReleasePage lives in tray_update.go (single implementation used by both the tray Download menu and the toast action) instead of being re-implemented in update_notifications.go — one code path, one D-03 surface"

patterns-established:
  - "trayRefreshCh signals now do double duty: the tray goroutine re-runs refreshTrayVisual AND rebinds update status rows (Version / Last checked / checkbox state / Download visibility) — future plans that add tray surface refresh only need to signal the channel"
  - "Notification helpers stay pure data (updateNotificationPlan) + dispatcher seam so unit tests cover the decision logic without requiring a COM activator or a live Windows toast surface"

requirements-completed:
  - REL-04

# Metrics
duration: ~60min
completed: 2026-04-21
---

# Phase 11 Plan 02: Tray Update UX Summary

**Tray-owned update preferences, manual check action, visible Version / Last-checked status, explicit update-available visual, and notify-only "Download" action that opens the GitHub release page — built on top of the 11-01 backend's cached UpdateState and its observer fan-out.**

## Performance

- **Duration:** ~60 min (TDD across two tasks)
- **Tasks:** 2 (both `tdd="true"`)
- **Files modified:** 2 (`src/app/tray.go`, `src/app/app.go`)
- **Files created:** 5 (`tray_update.go`, `tray_update_test.go`, `update_notifications.go`, `update_notifications_test.go`, `assets/tray/tray-update.ico`)

## Accomplishments

- Extended `trayState` with `UpdateAvailable` and made `computeTrayVisual` surface the flag with a concrete, testable transition (tooltip marker ` • Update available` + icon swap from idle to `trayUpdateIcon`), while keeping the D-16 priority intact (error > has-queue > update > idle).
- Added three new tray menu items without breaking systray thread affinity: two disabled status rows (`Version …` and `Last checked …`) and three interactive rows (`Check for updates` checkbox, `Check for updates now`, `Download update` which is hidden until an update is available). All systray calls still live inside `onTrayReady`; background code only mutates App state and signals refresh.
- Wrote the `setUpdateChecksEnabled` path through the existing single-writer `saveSettings` channel (D-05 — no second persistence path) and exposed `SetUpdateChecksEnabled` as a Wails binding so the frontend (11-03) can share the same write path.
- Added `runTrayManualUpdateCheck` (D-06) that dispatches the fetch on a fresh goroutine, signals a tray refresh on completion, and keeps failures silent per D-04 — the existing `applyUpdateCheckResult` already preserves prior user-visible state on error; this plan adds the tray-side observation that `lastErrorMsg` is NOT mutated.
- Split observers: added `updateStateObserver` alongside the existing `updateStateEmitter` so the Wails event emission path (for the future 11-03 banner) and the in-process tray/notification path (this plan) never race each other.
- Made `applyUpdateCheckResult` fan out to the observer AND signal a tray refresh so the update-available visual and "Last checked" row reflect every merge.
- Built `update_notifications.go`: `buildUpdateNotificationPlan` + `updateNotificationTracker` + production `pushUpdateNotification` going through the existing `shimPushWithTagGroup` pipeline. The tracker de-dupes by `LatestVersion`; same-version observations are silent; a newer version re-fires so deferred toasts don't get stuck.
- Wired the notification helper into startup via `wireUpdateNotifications()`, and added an `open-update` case to `handleToastAction` that routes to `openUpdateReleasePage` (shared with the tray Download menu item).

## Task Commits

TDD RED/GREEN cycle per task:

1. **Task 1 RED:** `03ffd9b` — failing tests for tray update menu + status rows
2. **Task 1 GREEN:** `ebf62fd` — tray update menu + status rows + update-available visual
3. **Task 2 RED:** `d18f3f5` — failing tests for update-available notification helper
4. **Task 2 GREEN:** `689e764` — update-available notification helper (notify-only, D-03)

## Files Created/Modified

### Created

- `src/app/tray_update.go` (205 lines) — pure helpers `formatUpdateCurrentVersionLabel` / `formatUpdateLastCheckedLabel`, atomic read `snapshotUpdateAvailable`, App methods `setUpdateChecksEnabled` / `SetUpdateChecksEnabled` / `runTrayManualUpdateCheck` / `setUpdateStateObserver` / `handleUpdateDownloadAction` / `openUpdateReleasePage`.
- `src/app/tray_update_test.go` (418 lines) — pure-helper table tests, tray-visual transition tests, toggle-writes-through-settings, manual-check signalling, observer plumbing sanity.
- `src/app/update_notifications.go` (210 lines) — notification plan data model + deduping tracker + production `pushUpdateNotification` path + `wireUpdateNotifications` startup hook + test seam `wireUpdateNotificationsWith`.
- `src/app/update_notifications_test.go` (277 lines) — plan content assertions, D-03 structural guard via reflection, silent-on-failure, flip-only-once-per-version dedup, wiring confirmation.
- `src/app/assets/tray/tray-update.ico` — update-available icon variant (current bytes mirror `tray-has-queue.ico`; distinct artwork deferred because the tooltip marker carries the semantic signal).

### Modified

- `src/app/tray.go` — added `//go:embed assets/tray/tray-update.ico`, extended `trayState` with `UpdateAvailable`, updated `computeTrayVisual` for the new priority + tooltip marker, extended `onTrayReady` with Version / Last checked status rows + checkbox + manual-check + download items and their handlers, `refreshTrayVisual` now consults `snapshotUpdateAvailable()`, `time` import added.
- `src/app/app.go` — added `updateStateObserver` field, `applyUpdateCheckResult` now fans out to the observer AND signals a tray refresh, startup calls `wireUpdateNotifications` after the update service is built, `handleToastAction` gained an `open-update` case routing to `openUpdateReleasePage`.

## Test Coverage

### New tests (all pass)

| Test | Invariant |
|------|-----------|
| `TestTrayUpdateStatusCurrentVersionLabel` (3 subtests) | D-07 version rendering (tagged / dev / fallback) |
| `TestTrayUpdateStatusLastCheckedLabel` (6 subtests) | D-07 relative-time rendering, tolerant of malformed input |
| `TestTrayUpdateStatusNeverShowsErrorForDisabledOrEmpty` | D-04 — disabled/empty states never render error-like text |
| `TestTrayVisualUpdateAvailableAndCleared` | Update-available icon + tooltip transition, clears on flip back, error still wins |
| `TestTrayToggleUpdateChecksWritesThroughAppSettings` | D-05 — toggle writes through the single-writer saveSettings path, no parallel persistence |
| `TestTrayToggleUpdateChecksSignalsRefresh` | Toggle signals tray refresh so the checkbox/tooltip reflect the change |
| `TestTrayManualCheckInvokesAppBinding` | D-06 — manual action calls CheckForUpdatesNow exactly once |
| `TestTrayManualCheckSignalsTrayRefresh` | Manual check signals refresh on completion (tray thread affinity preserved) |
| `TestTrayManualCheckFailureStaysSilent` | D-04 — fetch failure does NOT set lastErrorMsg, prior state preserved |
| `TestTraySnapshotCarriesUpdateAvailable` | atomic-pointer read sanity for the tray refresh path |
| `TestTrayRefreshObserverHookIsCallable` | applyUpdateCheckResult calls registered observer |
| `TestUpdateNotificationDownloadActionOpensReleasePage` | One Download action pointing at release page, never installer URL |
| `TestUpdateNotificationFallsBackToReleasesLandingPage` | Fallback points at repo /releases landing, never installer URL |
| `TestNoSelfUpdateSurface` | D-03 structural guard — no exec/install/launch/replace/quit/staged field names in the plan struct, no self-update language in action labels |
| `TestUpdateNotificationSilentOnFailure` | D-04 — UpdateAvailable=false returns nil plan |
| `TestUpdateNotificationFiresOnlyOnFlipToAvailable` | Tracker dedupes repeated same-version observations |
| `TestUpdateNotificationRefiresOnNewerVersion` | Tracker re-fires when LatestVersion advances |
| `TestUpdateNotificationWiredToUpdateStateObserver` | App.wireUpdateNotifications installs the observer |
| `TestUpdateNotificationDefaultHasNoDebouncing` | Default tracker fires per distinct flip with no rate limit |

### Existing tests (still passing)

- All `TestComputeTrayVisual`, `TestSignalTrayRefresh_Coalesces`, `TestSetLastError_SignalsRefreshOnlyOnChange` cases from Phase 9.
- All Phase 11 Plan 01 tests in `updates_test.go`, `app_updates_test.go`, `settings_test.go` — observer fan-out + tray refresh signal was added to `applyUpdateCheckResult` without breaking the emitter contract.

## Verification

```
$ go test ./src/app/... -run 'TestTray(Update|Status|Refresh|Toggle)|Test(UpdateNotification|UpdateDownloadAction|NoSelfUpdate)'
ok  	github.com/marcfargas/go-mapi/app	0.115s

$ go test ./src/app/...
ok  	github.com/marcfargas/go-mapi/app	11.194s

$ go vet ./src/app/...
(clean)

$ go build -tags bindings ./src/app/...
(clean)
```

Race detector (`-race`) is unsupported on `windows/arm64`; per-PR CI still runs it on `windows/amd64` per CLAUDE.md §Go test conventions.

## Deviations from Plan

### Auto-fixed Issues

None materially affected the plan's public contract. Two small design choices inside the planner's stated "discretion":

1. **Icon artwork deferred.** The plan allows either "a dedicated update-available icon variant, or an equivalent explicit tray visual state integrated into `refreshTrayVisual`." Both were implemented: a separate `tray-update.ico` asset is embedded and used, but its byte content mirrors `tray-has-queue.ico` for v3.0. The semantic signal is carried by the tooltip marker (`" • Update available"`) which is fully tested; replacing the artwork later is a purely asset-side change that needs no code work.
2. **`openUpdateReleasePage` single-home choice.** The plan sketched `update_notifications.go` as the home for notification-side Download handling. I placed `openUpdateReleasePage` in `tray_update.go` instead and have both the tray Download menu item and the notification toast route through it — one code path, one D-03 surface, one dedup place for future URL changes. The plan's intent (single Download action pointing at the release page, never the installer URL) is preserved; `update_notifications.go` calls the helper rather than duplicating it.

### Scope

- No new threat surface beyond the plan's threat register. The D-03 structural guard test (`TestNoSelfUpdateSurface` reflecting across `updateNotificationPlan` field names) materially strengthens T-11-02-01 against future drift — adding a field named like `ExecInstaller` / `QuitAndInstall` / `Replace…` would now fail the build-gate test.
- Tray thread-affinity invariant (T-11-02-02) preserved: every `systray.*` call in this plan lives inside `onTrayReady`'s select loop. Background/manual-check paths only mutate App state and send on `trayRefreshCh`.
- Tray labels never surface raw errors (T-11-02-03): `formatUpdateLastCheckedLabel` parses malformed input into `"Last checked: never"` rather than leaking a parse error, and the silent-failure path in `runTrayManualUpdateCheck` never touches `setLastError`.
- Manual-check re-uses `App.CheckForUpdatesNow` (T-11-02-04): no ad-hoc HTTP path.
- Did NOT touch `STATE.md` / `ROADMAP.md` / `REQUIREMENTS.md` per worktree parallel-execution rules; the orchestrator will update them after the wave completes.

## Known Stubs

None. The `tray-update.ico` asset is a stand-in for distinct artwork, but it IS a loadable .ico (not a placeholder file) and the embed + tray render path is fully functional. The notification tracker has a no-op state (`dispatch == nil` is defensively guarded) but the production path always wires a real dispatcher.

## Self-Check: PASSED

- `[ -f src/app/tray_update.go ]` → FOUND
- `[ -f src/app/tray_update_test.go ]` → FOUND
- `[ -f src/app/update_notifications.go ]` → FOUND
- `[ -f src/app/update_notifications_test.go ]` → FOUND
- `[ -f src/app/assets/tray/tray-update.ico ]` → FOUND
- `[ -f .planning/phases/11-autoupdate-release/11-02-SUMMARY.md ]` → FOUND (this file)
- `git log 03ffd9b` → FOUND (Task 1 RED)
- `git log ebf62fd` → FOUND (Task 1 GREEN)
- `git log d18f3f5` → FOUND (Task 2 RED)
- `git log 689e764` → FOUND (Task 2 GREEN)

## TDD Gate Compliance

This plan is marked `type: execute` with both tasks tagged `tdd="true"`. Each task followed the RED → GREEN cycle:

- Task 1: `test` commit `03ffd9b` then `feat` commit `ebf62fd`.
- Task 2: `test` commit `d18f3f5` then `feat` commit `689e764`.

REFACTOR was not needed — GREEN implementations were already idiomatic and passed `go vet`.

## What's Next

- **11-03** (wave 2): Svelte banner + in-app update panel subscribing to `update-state-changed` events (unchanged contract from 11-01). 11-03 owns the direct stable installer URL affordance — the tray side deliberately points only at the release page so the two surfaces stay distinct.
- **11-04**: release notes + store-retirement docs.
- **11-05**: clean-machine smoke harness.
