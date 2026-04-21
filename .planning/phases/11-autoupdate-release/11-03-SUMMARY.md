---
phase: 11-autoupdate-release
plan: 03
subsystem: ui
tags: [svelte, svelte5-runes, wails, frontend, updates, github-releases, notify-only]

requires:
  - phase: 11-autoupdate-release
    provides: "Plan 11-01 — App-owned UpdateState, GetUpdateState binding, CheckForUpdatesNow binding, update-state-changed Wails event, AppSettings.UpdateChecksEnabled persistence"

provides:
  - Typed `UpdateState` frontend contract shared with Go via auto-generated `main.UpdateState`
  - `lib/settings.ts` thin wrappers — `fetchUpdateState`, `checkForUpdatesNow`, `subscribeUpdateState`
  - `UpdateBanner.svelte` — small persistent update-available banner (D-01)
  - `UpdatePanel.svelte` — in-app panel exposing release page + stable installer URL (D-02) with current version + last checked (D-07) and the single D-08 "enabled by default" callout
  - Root-shell hydration that loads update state in the existing `Promise.all` on mount and re-renders on `update-state-changed` events without page reloads

affects: [11-04, 11-05]

tech-stack:
  added:
    - "@testing-library/svelte — extended mock patterns for Wails context auto-injection and BrowserOpenURL"
  patterns:
    - "Thin typed wrappers over wailsjs bindings in lib/settings.ts (matches existing fetchSettings/subscribeAutoDraftResult style)"
    - "External-URL affordances route through Wails BrowserOpenURL, never plain <a href> (WebView2 otherwise navigates in-app)"
    - "Prop naming in Svelte 5 runes mode avoids `state` (reserved identifier conflicts with $state rune; use domain-specific prop names like `update`)"
    - "Root shell hydrates optional async state with `.catch(() => null)` inside Promise.all so a failing backend service never blocks app startup"

key-files:
  created:
    - src/app/frontend/src/lib/components/UpdateBanner.svelte
    - src/app/frontend/src/lib/components/UpdatePanel.svelte
  modified:
    - src/app/frontend/src/lib/settings.ts
    - src/app/frontend/src/lib/settings.test.ts
    - src/app/frontend/src/App.svelte
    - src/app/frontend/src/App.test.ts
    - src/app/frontend/wailsjs/go/main/App.d.ts
    - src/app/frontend/wailsjs/go/main/App.js
    - src/app/frontend/wailsjs/go/models.ts
    - package-lock.json

key-decisions:
  - "Regenerated wailsjs bindings (`wails generate module`) rather than stubbing against an expected shape — the generated `main.UpdateState`, `GetUpdateState`, and `CheckForUpdatesNow` landed cleanly from plan 11-01's Go side, so the typed wrapper can import real types."
  - "Renamed the UpdatePanel prop from `state` to `update` because Svelte 5 runes mode treats `state` as a reserved identifier and a prop destructured as `state` collides with the `$state` rune at runtime (`store_invalid_shape` error)."
  - "Panel close does NOT mutate `bannerDismissedForVersion` so the banner remains persistent across open/close cycles (D-01 persistence). The `bannerDismissedForVersion` state field is reserved for a future dismissal UX without suppressing the current-version banner."
  - "External URLs (GitHub release page + stable installer) route through Wails BrowserOpenURL. Plain `<a href>` would make WebView2 try to navigate inside the app window instead of opening the user's system browser."
  - "checkForUpdatesNow wrapper swallows rejections at the frontend edge (D-04 silent-failure rule). Backend already logs; UI never surfaces a red 'check failed' state for transient GitHub outages."

patterns-established:
  - "Svelte 5 runes-mode prop naming: avoid `state` for component props; use a domain-specific name (e.g., `update`)."
  - "Notify-only update UX: banner + panel mounted from App.svelte with no dedicated settings route, matching D-05's 'lightweight rather than full settings screen' direction."
  - "Frontend `*.test.ts` mocks BrowserOpenURL explicitly so link-routing behaviour is verifiable without a real WebView2."

requirements-completed: [REL-04]

duration: 1h 47min
completed: 2026-04-21
---

# Phase 11 Plan 03: Main-Window Update UX Summary

**Notify-only update UX: persistent banner + in-app panel over typed `lib/settings.ts` wrappers, wired to the plan 11-01 `update-state-changed` event for no-reload re-renders.**

## Performance

- **Duration:** 1h 47min
- **Started:** 2026-04-21T17:53:03Z
- **Completed:** 2026-04-21T19:40:09Z
- **Tasks:** 2 (both TDD)
- **Files modified:** 8 (5 handwritten + 3 regenerated wailsjs bindings)

## Accomplishments

- Shipped the D-01 persistent update banner and the D-02 in-app update panel without introducing a dedicated settings route or a second source of truth for update state.
- Added one typed frontend contract (`UpdateState`) consumed by every update affordance, backed by thin `lib/settings.ts` wrappers that hide Wails' context auto-injection for `CheckForUpdatesNow` and swallow transient failures per D-04.
- Hydrated update state inside the existing root-shell `Promise.all` mount pattern and wired the `update-state-changed` Wails event so long-running sessions re-render when the 24h scheduler or a manual check fires — no page reload, no duplicate client-side source of truth (threat T-11-03-03 mitigation).
- Locked the D-07 status (current version + last checked) and the D-08 "enabled by default" callout into the panel, with the single callout guaranteed by an `expect(callouts).toHaveLength(1)` regression test.

## Task Commits

Each task used the TDD RED/GREEN gate sequence.

1. **Task 1 RED: failing tests for settings.ts update wrappers** — `93d332a` (test)
2. **Task 1 GREEN: typed wrappers + root hydration** — `2dd1794` (feat)
3. **Task 2 RED: failing tests for UpdateBanner + UpdatePanel root wiring** — `5cac640` (test)
4. **Task 2 GREEN: UpdateBanner + UpdatePanel mounted from root shell** — `6b3883d` (feat)

## Files Created/Modified

**Created:**
- `src/app/frontend/src/lib/components/UpdateBanner.svelte` (67 lines) — small persistent banner with a single "View update" button that opens the panel.
- `src/app/frontend/src/lib/components/UpdatePanel.svelte` (251 lines) — modal update panel exposing the stable installer URL, the GitHub release page, current version / last checked status, the D-08 callout, and the manual "Check for updates now" action.

**Modified:**
- `src/app/frontend/src/lib/settings.ts` — export `UpdateState` (alias of `main.UpdateState`), `fetchUpdateState`, `checkForUpdatesNow`, `subscribeUpdateState`.
- `src/app/frontend/src/lib/settings.test.ts` — add coverage for the new wrappers plus update the pre-existing `saveSettings` fixture to match the plan-11-01 AppSettings shape.
- `src/app/frontend/src/App.svelte` — import the new components, hydrate `updateState` inside the existing `Promise.all`, subscribe to `update-state-changed`, gate the banner on `updateAvailable`, and mount the panel behind `showUpdatePanel`.
- `src/app/frontend/src/App.test.ts` — add 9 Phase 11-03 tests covering banner visibility gating, event-driven re-render, panel link routing through `BrowserOpenURL`, D-07 status, D-08 single callout, D-04 silent-failure, and manual-check wiring.
- `src/app/frontend/wailsjs/go/main/App.d.ts` / `App.js` / `../models.ts` — regenerated via `wails generate module` to expose `GetUpdateState`, `CheckForUpdatesNow`, `main.UpdateState`, and the new `AppSettings.update_checks_enabled` / `last_update_check` fields landed by plan 11-01.
- `package-lock.json` — populated after `npm ci` installed the frontend workspace devDependencies (needed to run vitest/svelte-check in the worktree).

## Decisions Made

- **Regenerate bindings in the worktree, don't stub.** The plan note allowed writing against an expected binding shape if regeneration was infeasible. Regeneration was feasible after dropping a placeholder `frontend/dist/index.html` for the `go:embed` gate — so we took the cleaner path and imported the real generated types.
- **Rename `state` → `update` in UpdatePanel.** Svelte 5 runes mode treats `state` as a reserved identifier in reactive contexts; the test run surfaced a `store_invalid_shape` runtime error before this was caught, which is now documented in-file as a gotcha for future components.
- **Keep `bannerDismissedForVersion` inert this phase.** The `$state` field is declared but intentionally not toggled by the panel close handler. D-01 calls for a persistent banner; a dismissal UX can land in a future plan without requiring a schema migration.
- **Route external URLs through `BrowserOpenURL`.** A plain `<a href>` would navigate inside the WebView2 window. This is now covered by the `BrowserOpenURL` mock in `App.test.ts` so future components regressing to anchor tags will fail CI.
- **Silent-failure wrapper at the frontend edge.** `checkForUpdatesNow` swallows promise rejections even though the backend also logs; this keeps D-04 intact regardless of which layer later gains a retry or surface-level error affordance.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Installed workspace devDependencies**
- **Found during:** Task 1 RED verification run.
- **Issue:** The worktree had no `node_modules/` — vitest could not load its config (`Cannot find package '@sveltejs/vite-plugin-svelte'`).
- **Fix:** Ran `npm ci` at the repo root (workspace root). 320 packages installed.
- **Files modified:** `package-lock.json` (populated for the first time in this worktree) — committed with the Task 1 RED commit per the lockfile-discipline rule.
- **Verification:** Vitest starts, loads the config, and runs through the suite.
- **Committed in:** `93d332a` (Task 1 RED).

**2. [Rule 3 — Blocking] Regenerated wailsjs bindings**
- **Found during:** Task 1 preparation (before RED).
- **Issue:** `wailsjs/go/main/App.d.ts` did not yet expose the `GetUpdateState`, `CheckForUpdatesNow`, or `main.UpdateState` symbols that plan 11-01 added on the Go side. The frontend wrappers could not `import` real types and would have had to be stubbed.
- **Fix:** Created a placeholder `src/app/frontend/dist/index.html` to satisfy the `go:embed` gate, ran `wails generate module`, then removed the placeholder.
- **Files modified:** `src/app/frontend/wailsjs/go/main/App.d.ts`, `App.js`, `wailsjs/go/models.ts`.
- **Verification:** `GetUpdateState`, `CheckForUpdatesNow`, and `UpdateState` now appear in the generated `.d.ts`. Frontend imports resolve to real types.
- **Committed in:** `93d332a` (Task 1 RED).

**3. [Rule 1 — Bug] Fixed pre-existing `saveSettings` test fixture**
- **Found during:** Task 1 GREEN svelte-check run.
- **Issue:** `settings.test.ts` had a `saveSettings({ mode: 'auto-draft' })` call that no longer type-checked because plan 11-01 added required `update_checks_enabled` / `last_update_check` fields to `AppSettings`. svelte-check failed with an `AppSettings missing` error.
- **Fix:** Updated the fixture to include `update_checks_enabled: true` so the call matches the current type.
- **Verification:** svelte-check passes with 0 errors.
- **Committed in:** `2dd1794` (Task 1 GREEN).

**4. [Rule 1 — Bug] Renamed UpdatePanel prop `state` → `update`**
- **Found during:** Task 2 GREEN first test run.
- **Issue:** Svelte 5 runes mode treats `state` as reserved; the prop collided with the `$state` rune and the runtime threw `store_invalid_shape` when the panel mounted.
- **Fix:** Renamed the prop to `update` across UpdatePanel.svelte + the App.svelte call-site, documented the gotcha in the component's header comment.
- **Verification:** All 19 App.test.ts tests pass, svelte-check is clean.
- **Committed in:** `6b3883d` (Task 2 GREEN).

**5. [Rule 1 — Bug] Removed redundant `role="region"` from UpdateBanner**
- **Found during:** Task 2 GREEN svelte-vite build.
- **Issue:** `vite-plugin-svelte` warned that `role="region"` on `<section>` is redundant because `<section>` with `aria-label` is already an implicit landmark region.
- **Fix:** Removed the explicit `role` attribute; kept `aria-label="Update available"` so tests and screen readers still target the landmark.
- **Verification:** No a11y warning from the Svelte compiler; App.test.ts `findByRole('region', { name: /update available/i })` still resolves.
- **Committed in:** `6b3883d` (Task 2 GREEN).

---

**Total deviations:** 5 auto-fixed (2 blocking infrastructure, 3 correctness)
**Impact on plan:** All five are necessary for correctness or tooling parity. None expand scope beyond the plan's files_modified list plus the intentionally-regenerated wailsjs bindings, which the plan's parallel-execution note explicitly permits.

## Issues Encountered

- **npm install was interrupted once.** The first `npm run test:run` invocation was interrupted by a stream watchdog timeout. All uncommitted work was preserved in the worktree; the session resumed from exactly that point, ran the tests to completion, and committed Task 1 GREEN cleanly. No work was lost.

## User Setup Required

None — no new external service configuration. The feature operates entirely on existing plan-11-01 backend state and public GitHub Releases endpoints already covered by the plan's threat register.

## Threat Flags

No new security surface introduced beyond what the plan's `<threat_model>` covered. Mitigations shipped as required:

- **T-11-03-01 Spoofing** — mitigated: UpdatePanel renders only backend-provided URLs (`update.latestReleaseUrl`, `update.installerUrl`); no user input reaches those fields.
- **T-11-03-02 DoS via UI noise** — mitigated: banner is gated on `updateAvailable`; D-04 silent-failure on hydration is covered by an explicit test (`does NOT show a user-visible failure banner`).
- **T-11-03-03 Frontend state drift** — mitigated: initial state comes from `fetchUpdateState()`; runtime updates come from one `update-state-changed` subscription; there is no parallel client-side source of truth.

## Known Stubs

None. All banner/panel affordances are wired to real backend data and Wails bindings; there are no hardcoded placeholders.

## Next Phase Readiness

- **Ready for 11-04 / 11-05:** The root shell now exposes a stable update UX surface. Tray work (if any lands in later plans) can subscribe to the same `update-state-changed` event without creating a parallel cache — the frontend and tray will render from the same App-owned `UpdateState`.
- **Blockers:** None. Self-check passes.

## Self-Check: PASSED

Files verified:
- src/app/frontend/src/lib/components/UpdateBanner.svelte
- src/app/frontend/src/lib/components/UpdatePanel.svelte
- src/app/frontend/src/lib/settings.ts
- src/app/frontend/src/lib/settings.test.ts
- src/app/frontend/src/App.svelte
- src/app/frontend/src/App.test.ts
- .planning/phases/11-autoupdate-release/11-03-SUMMARY.md

Commits verified:
- 93d332a (test: Task 1 RED)
- 2dd1794 (feat: Task 1 GREEN)
- 5cac640 (test: Task 2 RED)
- 6b3883d (feat: Task 2 GREEN)

Gates:
- Vitest: 83/83 passing (19 App.test.ts, 13 settings.test.ts, 51 others)
- svelte-check: 0 errors (2 pre-existing warnings in AutoDraftErrorBadge + QueueRow, out of scope)

---
*Phase: 11-autoupdate-release*
*Completed: 2026-04-21*
