---
gsd_state_version: 1.0
milestone: v3.0
milestone_name: Wails Pivot
status: executing
stopped_at: Phase 7 complete — Phase 8 unblocked
last_updated: "2026-04-17T21:08:31.524Z"
last_activity: 2026-04-17 -- OAuth verification submitted (video demo pending until 08-05)
progress:
  total_phases: 5
  completed_phases: 1
  total_plans: 9
  completed_plans: 4
  percent: 44
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-12)

**Core value:** A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.
**Current focus:** Phase 08 — oauth-credentials

## Current Position

Milestone: v3.0 Wails Pivot
Phase: 08 (oauth-credentials) — EXECUTING
Plan: 1 of 5
Status: Executing Phase 08
Last activity: 2026-04-15 -- Phase 08 execution started

Progress: [██░░░░░░░░] 20%

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

### Pending Todos

- AUTH-06: Google OAuth verification submitted 2026-04-17 (GCP client, consent screen, scope justifications done; 4-8 week review window running)
- AUTH-06b: Record and upload YouTube demo video for OAuth verification — blocked until Plan 08-05 ships end-to-end sign-in + draft flow. See `.planning/todos/pending/2026-04-17-oauth-verification-youtube-demo-video.md`

### Blockers/Concerns

- Google OAuth verification (AUTH-06) is a 4-8 week external dependency — late submission blocks launch
- Phase 7 measurement-methodology follow-up: iter 2/3 single-instance mutex race in `measure-ram.ps1` (see 07-VERIFICATION.md §Methodology Caveats). Not a blocker; only matters if RAM gate needs re-running.

### Resolved

- ~~RAM profile under RDS conditions is unvalidated~~ — RESOLVED 2026-04-14: Phase 7 Plan 04 measured 43.24 MB mean per session on 5 concurrent sessions (n=4 clean), well under 80 MB gate; verdict PASS. Full report: 07-VERIFICATION.md.

## Session Continuity

Last session: 2026-04-14
Stopped at: Phase 7 complete — Phase 8 unblocked
Resume: run `/gsd-plan-phase 8` to begin planning OAuth + Credentials
