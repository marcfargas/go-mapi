---
gsd_state_version: 1.0
milestone: v3.0
milestone_name: Wails Pivot
status: defining-requirements
stopped_at: v3.0 milestone started — gathering requirements
last_updated: "2026-04-12T19:30:00.000Z"
last_activity: 2026-04-12
progress:
  total_phases: 0
  completed_phases: 0
  total_plans: 0
  completed_plans: 0
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-12)

**Core value:** A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.
**Current focus:** v3.0 Wails Pivot — standalone desktop app replacing the Chrome/Edge extension

## Current Position

Milestone: v3.0 Wails Pivot
Phase: Not started (defining requirements)
Plan: —
Status: Defining requirements
Last activity: 2026-04-12 — Milestone v3.0 started

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
- v3.0: Per-instance RAM budget 10–30 MB (RDS 30-user constraint)
- v3.0: Three-mode toggle — Auto-draft / Auto-send / Manual (default Manual)
- Preserved: MAPI DLL, filesystem IPC, delete-on-process privacy model

### Pending Todos

None yet.

### Blockers/Concerns

- WebView2 runtime delivery strategy — Evergreen (auto-installs) vs fixed-version bundle; impacts installer size and update cadence
- RAM profile under RDS conditions is an assumption, not measured — must validate early

## Session Continuity

Last session: 2026-04-12
Stopped at: v3.0 milestone kickoff — Wails pivot scoping
Resume: continue `/gsd-new-milestone` flow to define requirements and roadmap
