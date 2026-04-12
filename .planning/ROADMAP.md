# Roadmap: go-mapi

## Milestones

- ✅ **v2.0.0 Installer UX + Test-Suite Completeness** — Phases 1-5 (shipped 2026-04-12) — see `milestones/v2.0.0-ROADMAP.md`
- ✅ **v2.1.0 Release Pipeline (capped)** — Phase 6 only; Phases 7-9 dropped for v3.0 Wails pivot (shipped 2026-04-12) — see `milestones/v2.1.0-ROADMAP.md`
- 📋 **v3.0 Wails Pivot** — planned; extension replaced by standalone Wails desktop app (see `.planning/notes/2026-04-12-architecture-reeval-wails.md`)

## Phases

<details>
<summary>✅ v2.0.0 Installer UX + Test-Suite Completeness (Phases 1-5) — SHIPPED 2026-04-12</summary>

- [x] Phase 1: Foundation & SignPath Application (8/8 plans) — completed 2026-04-10
- [x] Phase 2: Extension Install UX (4/4 plans) — completed 2026-04-10
- [x] Phase 3: Inno Setup Installer + Signing + Distribution (4/4 plans) — completed 2026-04-10
- [x] Phase 4: Test-Suite Completeness + E2E (4/4 plans) — completed 2026-04-10
- [x] Phase 5: Release Cut (4/4 plans) — completed 2026-04-12

Full details: `milestones/v2.0.0-ROADMAP.md`

</details>

<details>
<summary>✅ v2.1.0 Release Pipeline (capped) (Phase 6) — SHIPPED 2026-04-12</summary>

- [x] Phase 6: Changesets Monorepo Scaffold (3/3 plans) — completed 2026-04-12
- ~~Phase 7: Extension Publishing Pipeline~~ — dropped (v3.0 Wails pivot)
- ~~Phase 8: Host Release Pipeline~~ — dropped (v3.0 Wails pivot)
- ~~Phase 9: Pipeline Integration and Legacy Retirement~~ — dropped (v3.0 Wails pivot)

Full details: `milestones/v2.1.0-ROADMAP.md`

</details>

### 📋 v3.0 Wails Pivot (Planned)

**Milestone Goal:** Replace the browser-extension + native-host split with a standalone Wails (Go + WebView2) desktop app. C++ MAPI interceptor and filesystem IPC stay unchanged; UI moves to system tray + native window, enabling automode, toast notifications, and eventual in-app composer. Target RAM profile: 10-30 MB per instance (RDS constraint).

Phases TBD — run `/gsd-new-milestone` to scope.

Seed: `.planning/notes/2026-04-12-architecture-reeval-wails.md`

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Foundation & SignPath Application | v2.0.0 | 8/8 | Complete | 2026-04-10 |
| 2. Extension Install UX | v2.0.0 | 4/4 | Complete | 2026-04-10 |
| 3. Inno Setup Installer + Signing + Distribution | v2.0.0 | 4/4 | Complete | 2026-04-10 |
| 4. Test-Suite Completeness + E2E | v2.0.0 | 4/4 | Complete | 2026-04-10 |
| 5. Release Cut | v2.0.0 | 4/4 | Complete | 2026-04-12 |
| 6. Changesets Monorepo Scaffold | v2.1.0 | 3/3 | Complete | 2026-04-12 |

---
*Roadmap updated: 2026-04-12 — v2.1.0 archived; v3.0 Wails pivot staged*
