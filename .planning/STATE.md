---
gsd_state_version: 1.0
milestone: v2.0.0
milestone_name: milestone
status: executing
stopped_at: Completed 01-02-PLAN.md
last_updated: "2026-04-10T16:14:02.009Z"
last_activity: 2026-04-10
progress:
  total_phases: 4
  completed_phases: 0
  total_plans: 8
  completed_plans: 6
  percent: 75
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-10)

**Core value:** A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.
**Current focus:** Phase 1 — Foundation & SignPath Application

## Current Position

Phase: 1 (Foundation & SignPath Application) — EXECUTING
Plan: 7 of 8
Status: Ready to execute
Last activity: 2026-04-10

Progress: [░░░░░░░░░░] 0%

## Performance Metrics

**Velocity:**

- Total plans completed: 0
- Average duration: —
- Total execution time: 0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| - | - | - | - |

**Recent Trend:**

- Last 5 plans: —
- Trend: —

*Updated after each plan completion*
| Phase 01-foundation-signpath-application P01 | 3 min | 3 tasks | 4 files |
| Phase 01-foundation-signpath-application P03 | 1 min | 1 tasks | 1 files |
| Phase 01-foundation-signpath-application P05 | 5 min | 3 tasks | 5 files |
| Phase 01-foundation-signpath-application P06 | 5min | 2 tasks | 3 files |
| Phase 01-foundation-signpath-application P07 | 6 min | 1 tasks | 1 files |
| Phase 01-foundation-signpath-application P02 | 4 min | 2 tasks | 1 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Init: Coarse granularity → 4 phases, parallelism between Phase 2 (Extension UX) and Phase 3 (Installer)
- Init: SignPath Foundation application filed in Phase 1 because OSS approval takes weeks (Pitfall #2)
- Init: `go test -race` deferred to Phase 4 (GOTEST-03) because it depends on the FOUND-01 race fix landing in Phase 1 first
- Init: EXT-07 (placeholder→real URL swap) lives in Phase 3, not Phase 2, because the real GitHub Releases URL only exists when the installer is published
- Init: All TS/extension test work consolidated in Phase 4 (one "test completeness" boundary) rather than scattered across Phases 2 and 4
- [Phase 01-foundation-signpath-application]: Keep legacy Version field on OutgoingMessage alongside new HostVersion — additive, no protocol version bump — v1 extensions continue to read the legacy version field while Phase 2 EXT-03 consumes the new canonical hostVersion field
- [Phase 01-foundation-signpath-application]: Centralize host version in src/native-host/version.go, keep -ldflags -X main.Version=... path unchanged — Single source of truth without breaking the existing build pipeline since both files share package main
- [Phase 01-foundation-signpath-application]: Use dedicated NewGmailClientWithBase constructor instead of variadic options for GmailClient baseURL injection — Variadic signature would silently accept malformed calls like NewGmailClient(token, "a", "b"); dedicated alt constructor keeps the zero-arg default obvious and makes test-only call sites explicit
- [Phase 01-foundation-signpath-application]: Extract C++ pure conversion logic into go_mapi::message_converter namespace (free functions, not a class) for direct test access — Free functions in a nested namespace avoid friend declarations and header hackery; doctest targets can call them directly
- [Phase 01-foundation-signpath-application]: Use CMake OBJECT library for message_converter.cpp so DLL and future doctest target share the same compiled object file — OBJECT library with TARGET_OBJECTS avoids recompiling message_converter.cpp for the test binary and keeps ABI parity
- [Phase 01-foundation-signpath-application]: Keep GetOriginApplicationName in MapiImpl and populate msg.originApp in the DLL caller after invoking the pure converter — GetModuleFileNameExW requires a live process — not pure conversion; moving originApp assignment to the caller keeps the pure module testable
- [Phase 01-foundation-signpath-application]: FOUND-06: dual-path manifest rendering (Local reads .tmpl, Download inline); String.Replace() literal substitution; JSON-escape HOST_PATH backslashes before substitution
- [Phase 01-foundation-signpath-application]: SIGN-01 draft: defensive reviewer-facing framing with zero uses of 'intercept'; MAPI handler consistently described as standard Windows Mail client registration
- [Phase 01-foundation-signpath-application]: SIGN-01 draft: Chrome Web Store URL left as explicit PLACEHOLDER with forced filing decision for Marc; draft lives at .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md (out of repo tree so it does not ship in installer)
- [Phase 01-foundation-signpath-application]: FOUND-01 fix was one line moved (mail.HostVersion stamp before lock) — race report confirmed only HostVersion was mutated post-unlock, so GetEmails deep copy was unnecessary
- [Phase 01-foundation-signpath-application]: Use GOOS=windows GOARCH=amd64 CGO_ENABLED=1 go test -race — Go 1.26 windows/arm64 does not support the race detector, but the production x86_64 toolchain does and matches CI's windows-latest runner

### Pending Todos

None yet.

### Blockers/Concerns

- SignPath Foundation approval timeline is unknown — file the application as the first action in Phase 1 so the clock starts immediately. Unsigned fallback (SIGN-03) gates release if approval lags.
- Existing `emails` map race from .planning/codebase/CONCERNS.md must be scoped before estimating FOUND-01 — run `go test -race ./...` once at the start of Phase 1 planning to size the work.

## Session Continuity

Last session: 2026-04-10T16:14:02.005Z
Stopped at: Completed 01-02-PLAN.md
Resume file: None
