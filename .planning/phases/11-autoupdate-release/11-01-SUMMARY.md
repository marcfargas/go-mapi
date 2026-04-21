---
phase: 11-autoupdate-release
plan: 01
subsystem: updates
tags: [updates, settings, github-releases, wails, go-selfupdate, cadence]

# Dependency graph
requires:
  - phase: 10-installer-migration
    provides: stable installer URL + wails.json version authority; Phase 11 cannot publish without it
  - phase: 09-queue-automode-toasts
    provides: AppSettings flat-field pattern + atomic-save discipline; Phase 11 extends it rather than creating a second config file
provides:
  - AppSettings.UpdateChecksEnabled (default true, D-08) and LastUpdateCheck (RFC3339)
  - src/app/updates.go notify-only updateService (CheckNow + MaybeCheck)
  - gitHubReleaseFetcher using GitHubSource.ListReleases (no DetectLatest asset matcher — 11-RESEARCH Pitfall 1)
  - App.GetUpdateState / App.CheckForUpdatesNow bindings for tray/frontend consumers
  - App-owned guarded writer (persistLastUpdateCheck) serialized with updateWriteMu
  - Long-lived update scheduler goroutine (1h ticks, 24h cadence floor)
  - update-state-changed Wails event for tray + frontend subscribers
affects: [11-02 tray update toggle + manual action, 11-03 banner/panel frontend, 11-04 release cutover]

# Tech tracking
tech-stack:
  added:
    - github.com/creativeprojects/go-selfupdate v1.5.2 (metadata-only; DetectLatest intentionally NOT used)
  patterns:
    - "Atomic-pointer cached state: atomic.Pointer[UpdateState] so readers never block refresh"
    - "Guarded single-writer for background persistence (persistLastUpdateCheck + updateWriteMu)"
    - "Test-injected releaseFetcher seam (avoids real HTTP in unit tests)"
    - "Silent-failure merge: applyUpdateCheckResult preserves prior LatestVersion on fetch error (D-04)"
    - "Scheduler-tick / startup-check share runGatedUpdateCheck so cadence logic lives in one place"

key-files:
  created:
    - src/app/updates.go
    - src/app/updates_test.go
    - src/app/app_updates_test.go
  modified:
    - src/app/settings.go
    - src/app/app.go
    - src/app/go.mod
    - src/app/go.sum
    - go.work.sum

key-decisions:
  - "Use go-selfupdate for GitHub release listing only (not DetectLatest) — our installer-only asset layout does not satisfy the library's {cmd}_{goos}_{goarch} naming rule"
  - "Hardcode owner/repo and installer URL constants — no settings-file control over where update checks point, blocking metadata redirection attacks (T-11-01-01)"
  - "Preserve prior UpdateAvailable / LatestVersion on fetch failure — D-04 silent-failure invariant means transient offlines must never wipe a visible update banner"
  - "Scheduler ticks every 1h but gate enforces 24h floor — multi-day sessions still recheck without hammering the API"
  - "Background goroutines persist LastUpdateCheck only through App-owned guarded writer; saveSettings direct-call invariant preserved"
  - "Dev-version strings (contain 'dev' or equal '0.0.0') treated as older than any tagged release so local dev builds still surface updates"

patterns-established:
  - "updateLogger typedef matches logInfo/logError signature — lets production wire real logging while tests pass nopLogger"
  - "updateSettings struct as MaybeCheck parameter (Enabled/LastUpdateCheck/Now) keeps cadence logic deterministic under test — no time.Now() mocking needed"
  - "Service state refresh separated from persistence: service returns pure data; App decides when/how to save via guarded writer"

requirements-completed:
  - REL-03
  - REL-05

# Metrics
duration: 10min
completed: 2026-04-21
---

# Phase 11 Plan 01: Auto-Update Backend + Settings Surface Summary

**App-owned notify-only update service with persisted opt-out, 24h cadence gate, and long-lived scheduler — ready for tray/frontend plans to consume a single cached UpdateState.**

## Performance

- **Duration:** 10 min
- **Started:** 2026-04-21T17:37:19Z
- **Completed:** 2026-04-21T17:47:45Z
- **Tasks:** 2
- **Files modified:** 3 (plus 3 test/data files created, go.mod/go.sum/go.work.sum deps)

## Accomplishments

- Extended AppSettings with flat update fields (UpdateChecksEnabled default-true per D-08, LastUpdateCheck RFC3339) without introducing a second config file (D-05); partial/legacy JSON files hydrate with correct defaults via `*bool` tri-state parse.
- Built the notify-only update service (`src/app/updates.go`) with a test-injectable `releaseFetcher` seam, metadata-only GitHub client using `ListReleases`, and zero download/replace surface (D-03 enforced by a dedicated test).
- Wired the App side: cached `UpdateState` (atomic.Pointer for lock-free reads), `GetUpdateState` / `CheckForUpdatesNow` bindings, guarded writer for LastUpdateCheck persistence, startup check + long-lived 24h scheduler, `update-state-changed` Wails event emission.
- D-04 silent-failure invariant: `applyUpdateCheckResult` preserves the prior user-visible LatestVersion / UpdateAvailable on transient fetch failures so a flaky network never clears a banner the user already saw.

## Task Commits

Each task was committed atomically following the TDD RED/GREEN cycle:

1. **Task 1 RED: failing tests for settings update fields + update service contract** — `e34465f` (test)
2. **Task 1 GREEN: update service contract + persisted update settings** — `3bcacf1` (feat)
3. **Task 2 RED: failing tests for startup/manual update wiring + scheduler** — `940cc3a` (test)
4. **Task 2 GREEN: startup + manual update checks + long-lived scheduler** — `91fa345` (feat)

## Files Created/Modified

### Created
- `src/app/updates.go` — notify-only `updateService`, `UpdateState` model, `releaseFetcher` seam, `gitHubReleaseFetcher` production impl, version-compare helpers (`compareSemver`, `isDevVersion`), stable installer URL constant.
- `src/app/updates_test.go` — service contract tests (defaults/opt-out/cadence/version-compare/silent-failure/no-replacement-surface) plus helper `saveSettingsRaw` and `nopLogger`.
- `src/app/app_updates_test.go` — App-level wiring tests (startup gated check, manual bypass, guarded writer concurrency, long-lived scheduler tick, state-change observer hook).

### Modified
- `src/app/settings.go` — extended `AppSettings`, added `defaultAppSettings()` builder, reworked `loadSettings` to use a tri-state `*bool` for the new toggle so partial JSON hydrates with `UpdateChecksEnabled=true`.
- `src/app/app.go` — added updater fields (`updates`, `updateState`, `updateWriteMu`, `updateStateEmitter`, `updateSchedulerStop`), new methods (`GetUpdateState`, `CheckForUpdatesNow`, `runStartupUpdateCheck`, `updateSchedulerTick`, `runGatedUpdateCheck`, `applyUpdateCheckResult`, `syncUpdateEnabledIntoState`, `persistLastUpdateCheck`, `startUpdateScheduler`), startup wiring (fetcher init + seed + startup check goroutine + scheduler launch), shutdown wiring (scheduler cancel before shutdownCancel).
- `src/app/go.mod` / `src/app/go.sum` / `go.work.sum` — added `github.com/creativeprojects/go-selfupdate v1.5.2` and its transitive deps.

## Test Coverage

- `TestSettingsUpdateDefaultsEnabled` — D-08 default-enabled invariant on first run.
- `TestSettingsUpdateBackCompatPartialJSON` — legacy Phase 9 `{"mode":"manual"}` files hydrate with `UpdateChecksEnabled=true`.
- `TestSettingsUpdateCorruptFallsBackToDefaults` — corrupt JSON returns full default AppSettings.
- `TestUpdateServiceOptOutSkipsFetch` — REL-05 opt-out suppresses network calls.
- `TestUpdateServiceRecentCheckSkipsFetch` / `TestUpdateServiceStaleCheckTriggersFetch` — REL-03 24h cadence gate.
- `TestUpdateServiceDetectsAvailableUpdate` / `TestUpdateServiceNoUpdateWhenCurrentIsLatest` / `TestUpdateServiceDevVersionSeesUpdate` — version compare correctness.
- `TestUpdateServiceFetchFailureIsReturnedNotPropagatedAsUserState` — D-04 silent-failure invariant on service layer.
- `TestUpdateServiceNoReplacementSurface` — D-03 enforced at the type/method level.
- `TestStartupUpdateRunsOneBackgroundCheckWhenStale` / `TestStartupUpdateSkippedWhenDisabled` / `TestStartupUpdateSkippedWhenRecent` — startup cadence gate behaviour.
- `TestCheckForUpdatesNowBypassesCadence` — D-06 manual action.
- `TestStartupUpdateFailureKeepsPriorStateUserInvisible` / `TestManualCheckFailurePreservesPriorState` — D-04 at the App layer.
- `TestGuardedLastUpdateCheckWriterSerializes` — 50-goroutine stress of `persistLastUpdateCheck` confirms no tmp-file leaks and no collateral field corruption.
- `TestUpdateSchedulerLongSessionRechecks` / `TestUpdateSchedulerRespectsOptOutAtRuntime` / `TestUpdateSchedulerSilentFailure` — recurring cadence across three scenarios.
- `TestUpdateStateChangeNotifiesObservers` — `update-state-changed` emitter contract.
- `TestGetUpdateStateAlwaysPopulatesCurrentVersion` — `GetUpdateState` never returns an uninitialized snapshot.

## Verification

```
$ go test ./src/app/... -run 'Test(Update|Settings|AppUpdate|CheckForUpdates|StartupUpdate)'
ok  	github.com/marcfargas/go-mapi/app	0.151s

$ go test ./src/app/...
ok  	github.com/marcfargas/go-mapi/app	10.558s

$ go vet ./src/app/...
(clean)

$ go build -tags bindings ./src/app/...
(clean)
```

Race detector (`-race`) is unsupported on `windows/arm64`; per-PR CI still runs it on `windows/amd64` per CLAUDE.md §Go test conventions.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] MaybeCheck needed a third return value for silent-failure preservation**

- **Found during:** Task 2 GREEN (running `app_updates_test.go` against the first implementation).
- **Issue:** Plan Task 2 Test 4 requires that failed startup/manual checks log the error and leave the previous user-visible state unchanged. The initial `MaybeCheck(ctx, settings) (state, checked)` contract swallowed the fetch error internally, leaving App-level callers unable to distinguish "successful fetch with no release yet" from "fetch failed → preserve prior state."
- **Fix:** Promoted `MaybeCheck` to `(UpdateState, bool, error)`. `runGatedUpdateCheck` now passes the error into `applyUpdateCheckResult`, which is the single place that knows to keep prior LatestVersion / UpdateAvailable on failure. Tests and the one production caller updated.
- **Files modified:** `src/app/updates.go`, `src/app/updates_test.go`, `src/app/app.go`.
- **Commit:** Part of `91fa345` (Task 2 GREEN).

### Scope

- No new threat surface beyond the plan's threat register. The hardcoded owner/repo/installer URL constants materially mitigate T-11-01-01 (metadata tampering) by ensuring release-body content can never redirect update checks or download URLs.
- No stubs flow to UI — this plan has no frontend scope; Phase 11 Plan 03 owns the banner/panel rendering.
- Did NOT touch `STATE.md` / `ROADMAP.md` / `REQUIREMENTS.md` per worktree parallel-execution rules; the orchestrator will update them after the wave completes.

## Known Stubs

None. `updateStateEmitter` is `nil` in tests by default (intentional — tests can opt in by setting it), but production startup always wires it to `wruntime.EventsEmit`. The scheduler goroutine is gated on `a.updates != nil` and the emitter on non-nil before invocation.

## Self-Check: PASSED

- `[ -f src/app/updates.go ]` → FOUND
- `[ -f src/app/updates_test.go ]` → FOUND
- `[ -f src/app/app_updates_test.go ]` → FOUND
- `[ -f .planning/phases/11-autoupdate-release/11-01-SUMMARY.md ]` → FOUND (this file)
- `git log e34465f` → FOUND (Task 1 RED)
- `git log 3bcacf1` → FOUND (Task 1 GREEN)
- `git log 940cc3a` → FOUND (Task 2 RED)
- `git log 91fa345` → FOUND (Task 2 GREEN)

## TDD Gate Compliance

This plan is marked `type: execute` with both tasks tagged `tdd="true"`. Each task followed the RED → GREEN cycle:

- Task 1: `test` commit `e34465f` then `feat` commit `3bcacf1`.
- Task 2: `test` commit `940cc3a` then `feat` commit `91fa345`.

REFACTOR was not needed — GREEN implementations were already idiomatic and passed `go vet`.

## What's Next

- **11-02** (wave 2): tray update toggle + `Check for updates now` menu item, wired to `GetUpdateState` / `CheckForUpdatesNow` / `SaveSettings` bindings from this plan.
- **11-03** (wave 2): Svelte banner + update panel subscribed to the `update-state-changed` event this plan emits.
- **11-04** / **11-05**: release-notes + store-retirement docs, clean-machine smoke harness.
