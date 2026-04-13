---
gsd_state_version: 1.0
milestone: v3.0
milestone_name: Wails Pivot
status: planning
stopped_at: Phase 7 context gathered
last_updated: "2026-04-13T06:41:09.029Z"
last_activity: 2026-04-12 — Roadmap defined (5 phases, 7-11)
progress:
  total_phases: 5
  completed_phases: 0
  total_plans: 0
  completed_plans: 0
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-12)

**Core value:** A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.
**Current focus:** v3.0 Wails Pivot — Phase 7: Wails Shell + RAM Gate

## Current Position

Milestone: v3.0 Wails Pivot
Phase: 7 — Wails Shell + RAM Gate (not started)
Plan: —
Status: Ready to plan
Last activity: 2026-04-12 — Roadmap defined (5 phases, 7-11)

Progress: [░░░░░░░░░░] 0%

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

- AUTH-06: Submit Google OAuth verification request on Phase 8 day 1 (4-8 week external review window)
- Phase 7 gate: RAM measurement result must be documented before Phase 8 planning begins

### Blockers/Concerns

- RAM profile under RDS conditions is unvalidated — Phase 7 must measure before any feature work proceeds
- Google OAuth verification (AUTH-06) is a 4-8 week external dependency — late submission blocks launch

## Session Continuity

Last session: 2026-04-13T06:41:09.014Z
Stopped at: Phase 7 context gathered
Resume: run `/gsd-plan-phase 7` to begin planning Phase 7
