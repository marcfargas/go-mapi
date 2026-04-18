# go-mapi

## What This Is

go-mapi intercepts Windows "Send to Mail recipient" calls from legacy desktop apps and routes them to Gmail as drafts (or sent mail). Starting in v3.0, it ships as a standalone Wails (Go + WebView2) desktop app with a system tray UI — the C++ MAPI DLL writes email JSON to a temp directory, and the app watches, previews, and (optionally) auto-processes them. For Windows users who want their legacy apps to compose email through Gmail without installing Outlook.

## Core Value

A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.

## Requirements

## Current Milestone: v3.0 Wails Pivot

**Goal:** Replace the Chrome/Edge extension + native-host split with a standalone Wails (Go + WebView2) desktop app that owns the UI, OAuth, notifications, and update loop. Retire the browser extension from CWS/Edge on ship. MAPI DLL, filesystem IPC, and privacy model are preserved unchanged.

**Target features:**
- Wails shell with system tray icon and native window (replaces extension popup)
- Queue viewer with per-action mode toggle: **Auto-draft / Auto-send / Manual**
- Google OAuth desktop app flow (loopback redirect) replacing `chrome.identity.getAuthToken()`
- Toast notifications when new emails arrive in the queue
- Opt-out autoupdate (Wails/WebView2 mechanism, verified during research)
- New signed installer + stable download URL; clean uninstall parity with v2.0 installer
- Retire Chrome/Edge extension from stores when v3.0 ships (clean break, users uninstall v2.x + install v3.0 fresh)

**Preserved from v2.x:**
- C++ MAPI interceptor DLL (unchanged)
- Filesystem-based IPC at `%TEMP%\go-mapi\` (unchanged)
- Privacy-first delete-on-process model (unchanged)
- Go as primary language (Wails uses Go backend + webview frontend)
- RFC 2822 MIME building + Gmail API draft/send flow (Go side)

**Key constraints:**
- **RAM in RDS**: Primary deployment target includes RDS environments with ~30 concurrent users on one server. Per-instance RAM budget is 10-30 MB (WebView2 shares the Edge runtime process — needs measurement during research)
- **Clean break migration**: Users uninstall v2.x, install v3.0 — no in-place upgrade path
- **Browser-independent**: Wails app must not depend on Chrome/Edge being installed (WebView2 runtime is separate)
- **Deferred to later milestones**: In-app composer (SMTP support prep), enterprise control plane for managed deployments

Seed: `.planning/notes/2026-04-12-architecture-reeval-wails.md`

### Validated

<!-- Shipped and confirmed valuable. -->

- ✓ One-click Windows installer (`.exe`) with DLL copy, registry keys, native host binary, native messaging manifests — v2.0.0
- ✓ Extension install prompt with direct download link + auto-detect success toast — v2.0.0
- ✓ Clean uninstall path (DLL, registry, manifests, temp files) — v2.0.0
- ✓ Test gap audit + high-risk gap filling (Go, TS, C++ message converter) — v2.0.0
- ✓ Playwright E2E happy-path test + `go test -race` in CI — v2.0.0
- ✓ SignPath Foundation application for code signing — v2.0.0
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
- ✓ Changesets monorepo with two private workspace packages (`src/extension`, `src/native-host`) on independent semver tracks — v2.1.0
- ✓ Version authority migrated from root `package.json` to per-package files; build scripts read per-package versions — v2.1.0
- ✓ Version Packages CI workflow via `changesets/action@v1.7.0` + `CHANGESET_TOKEN` PAT for downstream CI triggering — v2.1.0

### Active

<!-- v3.0 Wails pivot. All hypotheses until shipped. -->

**Wails shell:**
- [ ] Standalone Wails (Go + WebView2) desktop app replaces the extension popup
- [ ] System tray icon with queue-count badge + context menu
- [ ] Native window for queue viewing and per-email actions
- [ ] WebView2 runtime dependency handled at install time (not bundled; use Evergreen runtime)

**Queue & actions:**
- [ ] Queue viewer lists pending emails from `%TEMP%\go-mapi\` (parity with current popup)
- [ ] Per-action mode toggle: Auto-draft / Auto-send / Manual (default Manual)
- [ ] Toast notification when a new email arrives in the queue

**OAuth:**
- [ ] Google desktop app OAuth flow (loopback redirect) replaces `chrome.identity`
- [ ] Secure token storage (OS credential vault, not disk)

**Distribution:**
- [ ] Signed installer (SignPath) with stable download URL
- [ ] Opt-out autoupdate — Wails/WebView2 mechanism verified during research
- [ ] Clean uninstall (parity with v2.0 installer — registry, MAPI handler, temp dir)
- [ ] Chrome/Edge extension unpublished from CWS and Edge stores on v3.0 ship

**Non-functional:**
- [ ] Per-instance RAM ≤ 30 MB measured under RDS-like conditions (30 concurrent users on one server)
- [ ] Browser-independent: Wails app functions without Chrome/Edge installed

### Out of Scope

<!-- Explicit exclusions. Deferred to later milestones or rejected. -->

- Outlook / Microsoft 365 support — deferred to a future milestone; Gmail-first is the current focus
- Multi-account support (picking which Gmail account to draft in) — deferred to a future milestone
- SMTP / non-Gmail provider support — deferred to a future milestone
- Queue management features (bulk actions, filtering, search) — deferred to a future milestone
- Host self-update (auto-download + replace) — not a priority; users re-run the installer for updates
- macOS / Linux support — MAPI is Windows-only; cross-platform is not on the roadmap
- Mobile apps — web/desktop only
- Release announcements (social, blog, etc.) — out of scope; pipeline only

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
| Test completeness = risk-based gap filling, not numeric coverage target | Coverage numbers can be gamed; blast-radius prioritization matches the project's pragmatic-over-perfect philosophy | ✓ Good — extended to v3.0 Wails codebase in Phase 8.1 |
| E2E test covers happy path only, not exhaustive scenarios | Regression safety on the main flow is the priority; edge cases stay in unit/integration tests | — Pending |
| Code signing via free OSS service if available (SignPath.io), unsigned otherwise | Solo FOSS project budget; paid EV certs are out of scope | — Pending |
| Outlook / multi-account / SMTP / queue mgmt deferred to future milestones | Keep v2.0.0 scope tight; install UX + reliability first, then expand | — Pending |
| Decoupled release tracks (extension vs host) | Host is lean/stable, extension iterates frequently — separate version tracks prevent unnecessary host releases | ⚠️ Revisit — changesets foundation shipped v2.1.0; extension track retired with Wails pivot |
| Changesets for versioning + changelogs | Explicit changeset files per change, Version Packages PR flow, works with monorepo dual-package setup | ✓ Good — shipped v2.1.0 Phase 6 |
| Publish to both Chrome Web Store and Edge Add-ons | Extension already supports Edge; users on both browsers deserve auto-updates | — Dropped — browser extension being replaced with Wails desktop app in v3.0 |
| Cap v2.1.0 at Phase 6, drop Phases 7-9 | Extension auto-publish pipeline would be retired within weeks once Wails pivot lands; building throwaway infra is wasteful | — Pending (v3.0 validates) |
| Replace browser extension with standalone Wails (Go + WebView2) desktop app | Extension sandbox blocks automode/composer/enterprise features; CWS+Edge review cycles slow iteration; no Firefox path; WebView2 shares Edge runtime on Windows (better RAM profile for RDS than Electron) | — Pending (v3.0) |

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
*Last updated: 2026-04-12 after v2.1.0 milestone archive (capped at Phase 6) and v3.0 Wails pivot staging*
