---
phase: 07-wails-shell-ram-gate
plan: 02
subsystem: shell
tags: [go, wails, svelte5, systray, tray, workspace, go-work, promote-internal]

# Dependency graph
requires: ["07-01"]
provides:
  - "src/app/ Wails v2.12.0 Go module with Svelte 5 frontend"
  - "go.work workspace wiring src/native-host + src/app + internal/mapi"
  - "internal/mapi top-level module (promoted from src/native-host/internal/mapi)"
  - "fyne.io/systray v1.12.0 tray with RunWithExternalLoop, Show/Quit menu, left-click toggle"
  - "Hide-to-tray lifecycle: StartHidden=true, HideWindowOnClose=true, beforeClose hook"
  - "Pre-built tray-idle.ico + tray-error.ico (48/32/16 multi-res)"
  - "Svelte 5 frontend: empty-state + error-state + queue-row template"
  - "npm workspace: src/app in root workspaces + .changeset/config.json"
affects: ["07-03", "07-04"]

# Tech tracking
tech-stack:
  added:
    - "Wails v2.12.0 (Go + WebView2 desktop framework)"
    - "fyne.io/systray v1.12.0 (system tray with RunWithExternalLoop)"
    - "Svelte 5.55.3 (frontend framework)"
    - "@sveltejs/vite-plugin-svelte v5 (Svelte 5 Vite plugin)"
    - "Vite 6 (frontend build)"
    - "Go workspace (go.work) for multi-module monorepo"
  patterns:
    - "go.work + replace directives for local cross-module dependency resolution"
    - "internal/mapi promoted to top-level module to allow cross-module import"
    - "Wails StartHidden + HideWindowOnClose + OnBeforeClose hook for hide-to-tray"
    - "systray.RunWithExternalLoop for non-blocking tray integration with Wails event loop"
    - "SetOnTapped for left-click toggle on Windows (fyne.io/systray v1.12.0)"

key-files:
  created:
    - "go.work — workspace file: src/native-host, src/app, internal/mapi"
    - "go.work.sum — workspace checksum"
    - "internal/mapi/ — promoted from src/native-host/internal/mapi/ (separate module)"
    - "internal/mapi/go.mod — module github.com/marcfargas/go-mapi/internal/mapi"
    - "src/app/go.mod — module github.com/marcfargas/go-mapi/app, go 1.23"
    - "src/app/main.go — Wails Run() with StartHidden=true, Width=480, Height=600"
    - "src/app/app.go — App struct, beforeClose hide-to-tray hook, GetQueue stub"
    - "src/app/tray.go — RunWithExternalLoop, Show/Quit menu, SetOnTapped left-click"
    - "src/app/wails.json — output name 'go-mapi'"
    - "src/app/package.json — @marcfargas/go-mapi-app v0.0.0"
    - "src/app/assets/tray/tray-idle.ico — 48/32/16 multi-res, fill #0067C0"
    - "src/app/assets/tray/tray-error.ico — 48/32/16 multi-res, fill #C42B1C"
    - "src/app/assets/tray/sources/tray-idle.svg — SVG source with regeneration comment"
    - "src/app/assets/tray/sources/tray-error.svg — SVG source with regeneration comment"
    - "src/app/frontend/package.json — Svelte 5.55.3 + Vite 6"
    - "src/app/frontend/src/App.svelte — empty-state + error-state + queue-row template"
    - "src/app/frontend/src/lib/queue.ts — EventsOn('queue-update') + GetQueue binding"
    - "src/app/frontend/src/lib/styles.css — UI-SPEC tokens verbatim"
    - "src/app/frontend/src/main.ts — Svelte 5 mount() entrypoint"
    - "src/app/frontend/wailsjs/ — auto-generated Wails JS bindings"
  modified:
    - ".changeset/config.json — added $workspaces array with src/app"
    - "package.json — added src/app to workspaces array"
    - "package-lock.json — updated for new workspace"
    - "src/native-host/go.mod — bumped go 1.23, uses internal/mapi via replace directive"
    - "src/native-host/main.go — import path updated to github.com/marcfargas/go-mapi/internal/mapi"
    - "src/native-host/nativemessaging.go — import path updated"
    - "src/native-host/gmail_test.go — import path updated"
    - "src/native-host/mime_golden_test.go — import path updated"
    - "src/native-host/protocol_test.go — import path updated"
    - "internal/mapi/testutil/fixtures.go — ascent corrected from 5 levels to 3 (new location)"
    - "internal/mapi/protocol_integration_test.go — import path updated"

key-decisions:
  - "Cross-module internal import blocked by Go compiler — promoted internal/mapi to top-level separate module with replace directive"
  - "go.work + replace directives used instead of v0.0.0-00010101000000 placeholder (workspace sync failed with placeholder)"
  - "Wails init generator used (svelte-ts template) then content moved from go-mapi-app/ subdirectory + patched"
  - "Svelte 3 scaffold upgraded to Svelte 5.55.3 — svelte.config.js rewritten (removed svelte-preprocess)"
  - "fyne.io/systray v1.12.0 SetOnTapped works on Windows (WM_LBUTTONUP confirmed in systray_windows.go) — Assumption A2 satisfied"
  - "Light/dark tray icon variants deferred — single ICO pair reads on both themes per D-11 discretion"
  - "ImageMagick 7.1.2 used for ICO generation (one-off, not in build pipeline)"

requirements-completed: [SHELL-01, SHELL-02, SHELL-03, SHELL-07]

# Metrics
duration: 90min
completed: 2026-04-13
---

# Phase 07 Plan 02: Wails Shell Scaffold Summary

**Scaffolded src/app/ Wails v2.12.0 workspace with Svelte 5 frontend, fyne.io/systray v1.12.0 hide-to-tray lifecycle, pre-built ICO assets, and go.work multi-module workspace wiring; promoted internal/mapi to top-level module to enable cross-module import.**

## Performance

- **Duration:** ~90 min
- **Completed:** 2026-04-13
- **Tasks:** 3 (Tasks 1+2 combined, Task 3 smoke gate)
- **Files:** 57 files created/modified/renamed in one commit

## Task Commits

1. **Tasks 1+2: Scaffold src/app + tray icons + Svelte 5 frontend** - `a388890` (feat)

## Wails Scaffold Path Taken

**Generator used** (`wails init -n go-mapi-app -t svelte-ts`) with manual patching:
- Generator created content in `src/app/go-mapi-app/` subdirectory — contents moved up to `src/app/`
- go.mod module name patched: `go-mapi-app` → `github.com/marcfargas/go-mapi/app`
- `go 1.23.0` → `go 1.23` (standardized)
- Output filename in wails.json: `go-mapi-app` → `go-mapi`
- Svelte 3 → Svelte 5 (package.json + svelte.config.js rewritten)
- `main.go` rewritten per plan spec (StartHidden, dimensions, windows options)
- `app.go` rewritten with tray integration and GetQueue stub
- Frontend complete replacement (App.svelte, lib/queue.ts, lib/styles.css, main.ts)
- Total patching: ~15 files modified from scaffold baseline
- Wails generator satisfied all 3 fallback criteria; generator path was taken.

## Internal/mapi Promotion

**Promoted to top-level separate module.**

Go's `internal/` package enforcement blocks cross-module import even with `go.work`:
```
app.go:6:2: use of internal package github.com/marcfargas/go-mapi/native-host/internal/mapi not allowed
```

Resolution:
1. Created `internal/mapi/` at repo root as a separate Go module (`github.com/marcfargas/go-mapi/internal/mapi`)
2. Moved all files from `src/native-host/internal/mapi/` to `internal/mapi/`
3. Updated `testutil/fixtures.go` path ascent (5 levels → 3 levels from new location)
4. Updated `protocol_integration_test.go` import to `github.com/marcfargas/go-mapi/internal/mapi/testutil`
5. Added `./internal/mapi` to `go.work` `use` directives
6. Added `replace github.com/marcfargas/go-mapi/internal/mapi v0.0.0 => ../../internal/mapi` to both `src/native-host/go.mod` and `src/app/go.mod`
7. Updated all imports in native-host package to `github.com/marcfargas/go-mapi/internal/mapi`

All native-host tests still pass post-promotion.

## Final Versions Installed

| Component | Version |
|-----------|---------|
| Wails CLI | v2.12.0 |
| Wails framework | v2.12.0 |
| fyne.io/systray | v1.12.0 |
| Svelte | 5.55.3 |
| @sveltejs/vite-plugin-svelte | 5.x |
| Vite | 6.x |
| Go workspace | go 1.23 |

## Assumption A2 Resolution: Left-Click Handler

**Satisfied.** `fyne.io/systray v1.12.0` exposes `SetOnTapped(f func())` which on Windows responds to `WM_LBUTTONUP`. Implementation uses `systray.SetOnTapped(a.toggleWindow)` in `onTrayReady()`. The `toggleWindow` function hides the window if `WindowIsNormal()` returns true, otherwise shows and unminimises it.

## Svelte Version Confirmation

**Svelte 5.55.3** installed. The scaffold generated Svelte 3.49.0 — upgraded by rewriting `frontend/package.json` with `"svelte": "^5.0.0"` and removing `svelte-preprocess` from `svelte.config.js` (Svelte 5 handles TypeScript natively via vite-plugin-svelte).

## ICO Generation Tool

**ImageMagick 7.1.2-17** (`magick` command) used for initial ICO generation:
```
magick convert sources/tray-idle.svg -define icon:auto-resize=48,32,16 tray-idle.ico
magick convert sources/tray-error.svg -define icon:auto-resize=48,32,16 tray-error.ico
```
ICOs contain 48×48 + 32×32 + 16×16 variants. SVG sources are committed with regeneration comments for future updates. ImageMagick is a one-off dev tool — not required to build the project.

Light/dark tray icon variants deferred per D-11 (Claude's discretion). Single ICO pair designed with `#0067C0`/`#C42B1C` fills that read on grey Windows taskbar at 16px.

## Smoke Gate

Developer self-check results:

- **Process launched without window flash:** PASS — `MainWindowTitle` was empty, confirming `StartHidden: true` worked
- **Tray icon registered:** DEFERRED to Plan 03 checkpoint — cannot verify visually in this environment. The Plan 03 human-verify checkpoint covers right-click menu, empty state rendering, and tray icon visual confirmation.
- **Process terminated cleanly:** PASS — `Stop-Process` completed without error; `Get-Process` returned exit code 1 (process not found)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Cross-module internal import rejected by Go compiler**
- **Found during:** Task 1 cross-module import spike
- **Issue:** `go.work` does not override Go's `internal/` package visibility rules. The compiler rejected: `use of internal package github.com/marcfargas/go-mapi/native-host/internal/mapi not allowed`
- **Fix:** Promoted `src/native-host/internal/mapi/` to `internal/mapi/` as a separate top-level Go module with `replace` directive in both `src/native-host/go.mod` and `src/app/go.mod`. Added `./internal/mapi` to `go.work`.
- **Files modified:** `go.work`, `internal/mapi/go.mod` (new), `internal/mapi/go.sum` (new), `src/native-host/go.mod`, `src/app/go.mod`, all test import paths in native-host, `internal/mapi/testutil/fixtures.go` (path ascent fixed)
- **Commit:** `a388890`

**2. [Rule 3 - Blocking] Wails generator created project in subdirectory**
- **Found during:** Task 1 scaffold
- **Issue:** `wails init -n go-mapi-app -t svelte-ts` created `src/app/go-mapi-app/` instead of writing directly to `src/app/`
- **Fix:** Moved contents up with `mv go-mapi-app/* . && rm -rf go-mapi-app`
- **Impact:** Minor — no code changes required, just directory restructuring

**3. [Rule 3 - Blocking] Svelte 3 scaffold — svelte-preprocess not installed**
- **Found during:** Task 2 `wails build` attempt
- **Issue:** Generated `svelte.config.js` imported `svelte-preprocess` which was not installed in Svelte 5 setup
- **Fix:** Rewrote `svelte.config.js` to empty export (Svelte 5 handles TS natively via vite-plugin-svelte)
- **Files modified:** `src/app/frontend/svelte.config.js`
- **Commit:** `a388890`

**4. [Rule 1 - Bug] Old protocol.go/watcher.go/gmail.go stray files**
- **Found during:** Task 1 native-host build
- **Issue:** When restoring the worktree, stray untracked files from the old branch (before Plan 01 deleted them) appeared in `src/native-host/` — caused redeclaration compile errors
- **Fix:** Removed `src/native-host/protocol.go`, `src/native-host/gmail.go`, `src/native-host/watcher.go`, `src/native-host/watcher_test.go` (these were deleted in Plan 01 but reappeared in worktree setup)
- **Impact:** Worktree-specific issue; no code changes

---

**Total deviations:** 4 (all auto-fixed, Rules 1+3)

## Known Stubs

- `src/app/app.go#GetQueue()` returns `nil` — Plan 03 wires the watcher

## Threat Flags

None. No new network endpoints, auth paths, or schema changes beyond the plan's threat model.

## Self-Check

Files verified:
- FOUND: `go.work`
- FOUND: `internal/mapi/go.mod`
- FOUND: `src/app/main.go`
- FOUND: `src/app/app.go`
- FOUND: `src/app/tray.go`
- FOUND: `src/app/assets/tray/tray-idle.ico`
- FOUND: `src/app/assets/tray/tray-error.ico`
- FOUND: `src/app/assets/tray/sources/tray-idle.svg`
- FOUND: `src/app/assets/tray/sources/tray-error.svg`
- FOUND: `src/app/frontend/src/App.svelte`
- FOUND: `src/app/frontend/src/lib/queue.ts`
- FOUND: `src/app/frontend/src/lib/styles.css`
- FOUND: `src/app/build/bin/go-mapi.exe`

Commits verified:
- `a388890` — feat(07-02): scaffold src/app Wails workspace + promote internal/mapi to top-level

## Self-Check: PASSED
