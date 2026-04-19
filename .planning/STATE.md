---
gsd_state_version: 1.0
milestone: v3.0
milestone_name: Wails Pivot
status: ready
stopped_at: Phase 08.1 complete — ready for Phase 09
last_updated: "2026-04-19T00:30:00.000Z"
last_activity: 2026-04-19 -- Phase 08.1 verified passed (7/7 must-haves)
progress:
  total_phases: 6
  completed_phases: 3
  total_plans: 27
  completed_plans: 18
  percent: 67
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-12)

**Core value:** A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.
**Current focus:** Phase 9 — Queue, Automode + Toasts (next)

## Current Position

Milestone: v3.0 Wails Pivot
Phase: 08.1 (post-pivot-cleanup-and-test-coverage-review) — COMPLETE
Plan: 9 of 9
Status: Ready (next phase: 09 queue/automode/toasts)
Last activity: 2026-04-19 -- Phase 08.1 verified passed (7/7 must-haves)

Progress: [████████████████░░] 60% (3/5 phases complete — 7, 8, 8.1)

## Performance Metrics

**Velocity (v2.1.0):**

- Total plans completed: 3
- Phase 6 shipped 2026-04-12

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions carried into v3.0:

- v3.0: Replace browser extension with standalone Wails (Go + WebView2) desktop app — see seed note
- v3.0: Clean-break migration — users uninstall v2.x, install v3.0 fresh
- v3.0: Retire Chrome/Edge extension from stores on v3.0 ship
- v3.0: Per-instance RAM target ≤ 80 MB idle (revised from 10-30 MB per research; 30 MB remains stretch goal)
- v3.0: Two-mode toggle — Manual / Auto-draft (Auto-send deferred; out of scope for v3.0)
- v3.0: Stack locked — Wails v2.12.0, fyne.io/systray v1.12.0 (RunWithExternalLoop), Go 1.23, Svelte 5
- v3.0: OAuth via golang.org/x/oauth2 PKCE loopback; tokens in zalando/go-keyring (Windows Credential Manager)
- v3.0: Autoupdate notify-only via creativeprojects/go-selfupdate (no in-process binary replacement)
- v3.0: NSIS installer (not Inno Setup) — AppUserModelID + Start Menu shortcut + WebView2 bootstrapper
- Preserved: MAPI DLL, filesystem IPC, delete-on-process privacy model
- [Phase 08]: D-08/D-09/D-10 realised: package-level var oauthClientID/_Secret with ldflags -X targets, env-var fallback for wails dev, fail-fast guard before wails.Run
- [Phase 08]: Dev dotfiles at repo root: .env.local / .env.local.example live at C:\dev\go-mapi root, not under src/app/ (visibility preference)
- [Phase 08]: Build-tag split pattern required for wails build compatibility: any fatal startup guard in main.go must be extracted to a !bindings-tagged file so wailsbindings.exe can introspect types without triggering os.Exit
- [Phase 08]: D-11/D-12 realised: zalando/go-keyring v0.2.8 wired for Windows Credential Manager; keyring.ErrNotFound on Get/Delete is signed-out state (not error); service=go-mapi user=oauth-tokens
- [Phase 8.1]: KeyringStore interface seam in src/app/auth.go for cross-platform unit tests (fakeKeyringStore for non-Windows; realKeyringStore wraps zalando/go-keyring on Windows)
- [Phase 8.1]: Root npm workspaces empirically confirmed as ["src/app", "src/app/frontend"] — npm workspaces is flat, frontend sub-workspace cannot be auto-discovered from src/app/package.json
- [Phase 8.1]: Vitest + @testing-library/svelte 5 requires svelteTesting() Vite plugin (not documented in PATTERNS but mandated by the library's README for runes mount() to pick the browser entry)
- [Phase 8.1]: CI convention — build-wails-app job on windows-latest, CGO_ENABLED=1, Go 1.25, per-PR -race + coverage for internal/mapi and src/app, svelte-check + Vitest blocking, wails build sanity
- [Phase 8.1]: Test hygiene debts carried forward (recorded in 08.1-REVIEW.md): WR-01 TestAuthCodeURLHasPKCE t.Parallel + package-var mutation pattern; WR-02 bootstrap-auth tests leak a goroutine to the real Google userinfo endpoint — both to fix in Phase 9 test pass

### Roadmap Evolution

- Phase 8.1 inserted after Phase 8 (2026-04-18): Post-pivot cleanup and test coverage review (URGENT) — purge v2.x native-host + browser-extension leftovers and shore up Wails codebase test coverage before Phase 9 feature work resumes
- Phase 8.1 completed 2026-04-19 (7/7 must-haves; 9 plans / 7 waves; 2 warnings routed as non-blocking test-hygiene follow-ups for Phase 9)

### Pending Todos

- AUTH-06: Google OAuth verification submitted 2026-04-17 (GCP client, consent screen, scope justifications done; 4-8 week review window running)
- AUTH-06b: Record and upload YouTube demo video for OAuth verification — blocked until Plan 08-05 ships end-to-end sign-in + draft flow. See `.planning/todos/pending/2026-04-17-oauth-verification-youtube-demo-video.md`

### Blockers/Concerns

- Google OAuth verification (AUTH-06) is a 4-8 week external dependency — late submission blocks launch
- Phase 7 measurement-methodology follow-up: iter 2/3 single-instance mutex race in `measure-ram.ps1` (see 07-VERIFICATION.md §Methodology Caveats). Not a blocker; only matters if RAM gate needs re-running.

### Resolved

- ~~RAM profile under RDS conditions is unvalidated~~ — RESOLVED 2026-04-14: Phase 7 Plan 04 measured 43.24 MB mean per session on 5 concurrent sessions (n=4 clean), well under 80 MB gate; verdict PASS. Full report: 07-VERIFICATION.md.

## Session Continuity

Last session: 2026-04-19T00:30:00.000Z
Stopped at: Phase 08.1 complete (7/7 verified, REVIEW + VERIFICATION committed)
Resume: run `/gsd-discuss-phase 9` to start queue/automode/toasts phase, or `/gsd-plan-phase 9` to skip discuss
