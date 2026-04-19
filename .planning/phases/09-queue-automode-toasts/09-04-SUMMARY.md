---
phase: 09-queue-automode-toasts
plan: "04"
subsystem: wails-bindings
tags: [wails-bindings, queue-actions, pause, mode-toggle, typescript]
dependency_graph:
  requires:
    - phase: 09-02
      provides: AppSettings struct + loadSettings/saveSettings + defaultMode constant
    - phase: 09-03
      provides: automode helpers (isPaused/SetPaused/getMode/setMode/isBacklogSkipped/markBacklogSkipped/pruneBacklogSkip), classifyAutomodeError, safeIDPrefix, gmailBaseURLOverride
  provides:
    - CreateDraftForID Wails binding (QUEUE-02)
    - DismissEmail Wails binding (QUEUE-03)
    - GetSettings/SaveSettings Wails bindings (QUEUE-04)
    - GetMode/SetMode convenience wrappers
    - PauseWatching/ResumeWatching/GetPausedState Wails bindings (SHELL-02 partial)
    - validateEmailID shared validator (T-9-08 mitigation)
    - Regenerated App.d.ts + App.js + models.ts with all 9 new bindings + AppSettings type
  affects:
    - 09-05 (mode toggle UI — calls GetSettings/SaveSettings/GetMode/SetMode)
    - 09-06 (toast notifications — calls CreateDraftForID/DismissEmail)
    - 09-07 (queue row UI — calls CreateDraftForID/DismissEmail)
    - 09-08 (tray menu — calls PauseWatching/ResumeWatching/GetPausedState)
tech_stack:
  added: []
  patterns:
    - validateEmailID guard at binding edge (T-9-08: reject empty/oversized IDs before watcher lookup)
    - idempotent unknown-id path in CreateDraftForID (returns nil when id not in queue)
    - D-10 invariant: CreateDraftForID does NOT call markBacklogSkipped (manual vs automode distinction)
    - gmailBaseURLOverride reused from automode.go for httptest injection in binding tests
    - GOMAPI_APPDATA_DIR env override in tests for settings isolation
key_files:
  created:
    - src/app/app_bindings_test.go
  modified:
    - src/app/app.go
    - src/app/frontend/wailsjs/go/main/App.d.ts
    - src/app/frontend/wailsjs/go/main/App.js
    - src/app/frontend/wailsjs/go/models.ts
key-decisions:
  - "CreateDraftForID uses gmailBaseURLOverride from automode.go rather than introducing a new override — reuses existing injection seam, avoids duplication"
  - "validateEmailID accepts any non-empty string <=128 chars (not strict hex) — watcher lookup by exact-match id is the real gate; over-strict validation at the binding edge would be fragile to future id format changes"
  - "SetPaused is also exposed as a Wails binding (it's exported) — harmless; PauseWatching/ResumeWatching are the canonical frontend API per plan"
  - "Tests use //go:build windows (settings.go is windows-only); no POSIX stub needed per 09-02 precedent"
requirements_closed: [QUEUE-02, QUEUE-03, QUEUE-04, QUEUE-07, SHELL-02]
duration: "~30 minutes"
completed: "2026-04-19"
---

# Phase 9 Plan 04: Wails Bindings for Queue Actions + Settings + Pause Summary

**9 new Wails bindings (CreateDraftForID, DismissEmail, GetSettings, SaveSettings, GetMode, SetMode, PauseWatching, ResumeWatching, GetPausedState) exposing Plan 02 + Plan 03 backend helpers to the Svelte frontend, with regenerated TypeScript declarations.**

## Performance

- **Duration:** ~30 minutes
- **Started:** 2026-04-19T15:35:00Z
- **Completed:** 2026-04-19T15:50:00Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments

- Added `validateEmailID` shared validator to `app.go` — rejects empty or oversized IDs at the binding edge (T-9-08 mitigation) before any watcher lookup or Gmail call.
- Implemented `CreateDraftForID`: looks up the email in the watcher snapshot, calls `MakeAuthenticatedGmailCall` → `GmailClient.CreateDraft` → `watcher.MarkProcessed`, emits `auto-draft-result` (success or failure with errorCategory) using the same `classifyAutomodeError` helper as automode. Unknown IDs return nil (idempotent — already processed). Does NOT populate `backlogSkip` (D-10 manual/automode distinction).
- Implemented `DismissEmail`: calls `watcher.Delete` (idempotent per Plan 03 Task 1). Auth-free by design — works when signed out.
- Implemented `GetSettings` / `SaveSettings`: read/write `AppSettings` via the `settingsMu`-guarded in-memory state + `setMode` delegate (which validates, persists, and wakes automode).
- Implemented `GetMode` / `SetMode`: thin wrappers over `getMode` / `setMode`.
- Implemented `PauseWatching` / `ResumeWatching` / `GetPausedState`: thin wrappers over `SetPaused` / `isPaused` (session-only, D-14/D-15).
- Created `app_bindings_test.go` (windows build tag): 21 tests covering all 9 bindings including failure paths (empty ID, unauthenticated, invalid_grant, idempotent dismiss, settings validation, disk persistence, pause/resume round-trip).
- Ran `wails generate module` to regenerate `App.d.ts`, `App.js`, `models.ts`. All 9 new bindings appear in the TypeScript declarations; `AppSettings { mode: string }` is now in the `main` namespace of `models.ts`.
- `svelte-check` passes with 0 errors (1 pre-existing a11y warning unrelated to this plan).
- Full Go test suite (`./internal/mapi/...` + `./src/app/...`) passes.

## Task Commits

| # | Name | Commit | Files |
|---|------|--------|-------|
| 1 | Add 9 App struct binding methods with tests | 1d174ae | src/app/app.go, src/app/app_bindings_test.go |
| 2 | Regenerate Wails TypeScript bindings | 1aeb7a9 | src/app/frontend/wailsjs/go/main/App.d.ts, App.js, models.ts |

## Files Created/Modified

- `src/app/app.go` — Added `validateEmailID`, `CreateDraftForID`, `DismissEmail`, `GetSettings`, `SaveSettings`, `GetMode`, `SetMode`, `PauseWatching`, `ResumeWatching`, `GetPausedState`; added `"errors"` and `"time"` imports
- `src/app/app_bindings_test.go` — New (windows build tag): 21 tests for all 9 bindings + `validateEmailID`
- `src/app/frontend/wailsjs/go/main/App.d.ts` — Regenerated: 9 new binding declarations added
- `src/app/frontend/wailsjs/go/main/App.js` — Regenerated: 9 new runtime wrappers added
- `src/app/frontend/wailsjs/go/models.ts` — Regenerated: `AppSettings { mode: string }` added to `main` namespace

## Decisions Made

- `CreateDraftForID` reuses `gmailBaseURLOverride` from `automode.go` for test httptest injection — avoids introducing a new package-level override var; the existing one covers both automode and manual-draft paths.
- `validateEmailID` accepts any non-empty string ≤128 chars rather than strict 64-char hex validation — the watcher's exact-match lookup is the real gate; over-strict regex would be fragile to future id format changes.
- `SetPaused` is exposed as a Wails binding (it's an exported method on App) — harmless side effect of `wails generate module`. `PauseWatching`/`ResumeWatching` are the documented frontend API per plan.
- Tests use `//go:build windows` following the 09-02 + 09-03 precedent (settings.go is windows-only and `saveSettings` is called by `SaveSettings`).

## Deviations from Plan

### Auto-fixed Issues

None.

### Intentional Scope Adjustments

**1. `SetPaused` appears in generated bindings alongside PauseWatching/ResumeWatching**
- **Found during:** Task 2 (wails generate module)
- **Decision:** `SetPaused` is exported (capital S) so `wailsbindings.exe` correctly includes it. This is harmless — the frontend should use `PauseWatching`/`ResumeWatching` per plan. No plan deviation.

## Known Stubs

None. All 9 bindings are fully implemented. The TypeScript declarations are regenerated from Go introspection — they are not hand-authored stubs.

## Threat Surface Scan

No new network endpoints, auth paths, or schema changes beyond what the plan's `<threat_model>` already covers:
- `CreateDraftForID` is validated (T-9-08), requires auth (T-9-09), emits `auto-draft-result` events (client-to-frontend only — no data flows back from frontend to trusted system through this path)
- `DismissEmail` is validated (T-9-08), auth-free by design, calls idempotent `watcher.Delete` (T-3 mitigation)
- Logging follows QUAL-03: `safeIDPrefix(id)` only, never subject/body/recipient

## Self-Check

Files exist:
- `src/app/app.go` — FOUND (modified)
- `src/app/app_bindings_test.go` — FOUND (created)
- `src/app/frontend/wailsjs/go/main/App.d.ts` — FOUND (regenerated)
- `src/app/frontend/wailsjs/go/main/App.js` — FOUND (regenerated)
- `src/app/frontend/wailsjs/go/models.ts` — FOUND (regenerated)

Commits exist:
- `1d174ae`: feat(09-04): add 9 App struct binding methods with tests — FOUND
- `1aeb7a9`: chore(09-04): regenerate Wails TypeScript bindings — FOUND

## Self-Check: PASSED
