# go-mapi

## What This Is

go-mapi is a three-tier bridge (C++ MAPI DLL → Go native host → Chrome/Edge extension) that intercepts Windows "Send to Mail recipient" calls and routes them to Gmail as drafts. It's for Windows users who want their legacy desktop apps to compose email through Gmail without installing Outlook.

## Core Value

A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.

## Requirements

### Validated

<!-- Inferred from existing code at v1.0.0. Shipped and in use. -->

- ✓ C++ DLL intercepts `MAPISendMail()` / `MAPISendMailW()` and writes email JSON to `%TEMP%\go-mapi\` — existing
- ✓ Windows registry integration under `HKLM:\SOFTWARE\Clients\Mail\go-mapi` for MAPI handler registration — existing
- ✓ Go native host watches `%TEMP%\go-mapi\`, debounces file writes, validates JSON, maintains in-memory queue — existing
- ✓ Native messaging protocol (4-byte length prefix + JSON) between Go host and Chrome extension — existing
- ✓ Chrome/Edge extension with React popup showing email queue (list + detail view) — existing
- ✓ OAuth 2.0 via `chrome.identity.getAuthToken()` with Gmail compose/send scopes — existing
- ✓ Gmail draft creation: Go builds RFC 2822 MIME locally (with attachments), POSTs to Gmail API `/drafts` — existing
- ✓ Delete-on-process privacy model (JSON files removed after draft created; session-only storage in extension) — existing
- ✓ Retry logic for AV-locked files (3 retries, 200ms backoff) and native host reconnect (6-second backoff) — existing
- ✓ PowerShell-based install script (`scripts/install.ps1`) for developers — existing
- ✓ Unit + integration tests for Go protocol, validator, watcher (~55 tests); protocol fixtures shared with TypeScript — existing
- ✓ CI builds all three components (DLL via MinGW+CMake, Go host, Vite extension bundle) via GitHub Actions — existing

### Active

<!-- v2.0.0 milestone scope. All hypotheses until shipped. -->

**One-click install for end users:**
- [ ] Pre-built Windows installer (single `.exe` or `.msi`) that handles DLL copy, registry keys, native host binary, and native messaging manifest in one run
- [ ] Extension detects when host is missing and shows an in-popup "Install" prompt with a direct download link (not a GitHub redirect)
- [ ] Installer is hosted at a stable direct-download URL so the extension can link to it without GitHub release UI
- [ ] Extension auto-detects when the host becomes available after install and shows a success toast (no manual reload)
- [ ] Code-sign the installer via a free OSS signing service (SignPath.io or equivalent); ship unsigned with clear SmartScreen guidance if no option lands
- [ ] Clean uninstall path that removes DLL, registry keys, native messaging manifest, and leftover temp files

**Test suite completeness:**
- [ ] Audit untested areas of the codebase (Go: `buildFullMIME`, Gmail HTTP client, logging; TypeScript: service worker, popup components; C++: DLL message conversion) and produce a gap list
- [ ] Fill the high-risk gaps identified in the audit (prioritized by blast radius, not coverage %)
- [ ] Add a Playwright (or equivalent) E2E test exercising the happy path: MAPI call → JSON file → queue → Gmail draft
- [ ] Run `go test -race` in CI to catch concurrency bugs in the watcher

**Polish:**
- [ ] Capture and fix rough edges discovered during daily use (to be logged as they arise, not pre-listed)

### Out of Scope

<!-- Explicit exclusions. Deferred to later milestones or rejected. -->

- Outlook / Microsoft 365 support — deferred to a future milestone; Gmail-first is the current focus
- Multi-account support (picking which Gmail account to draft in) — deferred to a future milestone
- SMTP / non-Gmail provider support — deferred to a future milestone
- Queue management features (bulk actions, filtering, search) — deferred to a future milestone
- Host self-update (auto-download + replace) — not a priority for v2.0.0; users re-run the installer for updates
- 80% line-coverage target or similar numeric gate — rejected in favor of risk-based gap filling
- macOS / Linux support — MAPI is Windows-only; cross-platform is not on the roadmap
- Mobile apps — web/desktop only

## Context

**Technical environment:**
- Windows 10/11 only (MAPI is a Windows API)
- Three-language stack: C++17 (DLL, MinGW), Go 1.21 (native host), TypeScript 5.3 + React 18 (extension)
- Build: npm scripts orchestrate CMake, `go build`, and Vite
- Distribution: Chrome Web Store for extension; host binaries built via CI but not yet packaged as a user-facing installer

**Prior work:**
- v1.0.0 shipped recently (commit `18d4a92`) with the full three-tier bridge working end-to-end for developers
- Current install path is `scripts/install.ps1` — requires admin PowerShell, MinGW, Go, and CMake on the user's machine, which makes v1.0.0 effectively developer-only
- Codebase was mapped on 2026-04-10 (`.planning/codebase/`) — ARCHITECTURE, STACK, STRUCTURE, TESTING, CONVENTIONS, CONCERNS, INTEGRATIONS docs are current

**Known gaps (from TESTING.md):**
- `buildFullMIME()` in `gmail.go` — no direct tests, only fixture-validated
- Gmail HTTP client — no mocking or HTTP tests
- Extension TypeScript — not covered in the codebase map's test analysis
- C++ DLL — no tests at all
- No E2E tests; no `-race` flag in CI

**User context:**
- Marc is the solo author/maintainer and uses go-mapi personally
- The installer milestone is driven by wanting to share the tool with non-technical users without walking each one through a developer setup
- Privacy is a baseline, not a feature: no retention, no network calls outside Gmail API, EU/FOSS-first sensibilities

## Constraints

- **Platform**: Windows 10/11 only — MAPI is a Windows API, no cross-platform path exists
- **Licensing**: LGPL-3.0 (Marc's default for FOSS projects) — constrains dependency choices and installer tooling
- **Privacy**: No telemetry, no long-term storage of message content, no network calls outside the Gmail API — baseline for the project
- **Budget**: Solo maintainer, FOSS — code signing must be free or near-free (SignPath.io for OSS, or unsigned with SmartScreen guidance)
- **Distribution**: Extension ships via Chrome Web Store; host installer must be hostable at a stable direct URL reachable from the extension popup
- **Toolchain (dev)**: Windows + Node 18+ + Go 1.21 + MinGW + CMake 3.16+ — end users must not need any of this after v2.0.0

## Key Decisions

<!-- Decisions made during initialization. Add more as the milestone progresses. -->

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Target non-technical Windows users for v2.0.0 install UX | v1.0.0 is developer-only; the point of the tool is to be usable by anyone, not just devs | — Pending |
| Extension links directly to installer download (not a GitHub release page) | Non-technical users get confused by GitHub UI; want a single "click here to install" button | — Pending |
| Single-click installer + auto-detect success toast (no multi-step guide) | Simpler UX; installer does the work, extension just watches for the host to appear | — Pending |
| Host auto-update deferred to a future milestone | Not a priority; re-running the installer is acceptable until update volume justifies the complexity | — Pending |
| Test completeness = risk-based gap filling, not numeric coverage target | Coverage numbers can be gamed; blast-radius prioritization matches the project's pragmatic-over-perfect philosophy | — Pending |
| E2E test covers happy path only, not exhaustive scenarios | Regression safety on the main flow is the priority; edge cases stay in unit/integration tests | — Pending |
| Code signing via free OSS service if available (SignPath.io), unsigned otherwise | Solo FOSS project budget; paid EV certs are out of scope | — Pending |
| Outlook / multi-account / SMTP / queue mgmt deferred to future milestones | Keep v2.0.0 scope tight; install UX + reliability first, then expand | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-10 after initialization (v2.0.0 milestone kickoff)*
