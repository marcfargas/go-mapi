# Project Research Summary

**Project:** go-mapi v2.0.0 — Installer UX + Test-Suite Completeness
**Domain:** Windows native-host installer UX paired with a Chrome/Edge browser extension
**Researched:** 2026-04-10
**Confidence:** HIGH

## Executive Summary

go-mapi v1.0.0 is a working three-tier bridge (C++ MAPI DLL → Go native host → Chrome/Edge extension → Gmail drafts) that is currently developer-only because its install path requires MinGW, Go, CMake, and admin PowerShell. v2.0.0 closes that gap with a signed, one-click Inno Setup installer that the browser extension actively surfaces when the host is missing, and adds the test coverage the codebase needs to be shipped with confidence to non-technical users.

All four research dimensions converged on the same load-bearing stack decisions: **Inno Setup 6 for the installer, SignPath Foundation for free FOSS code signing, GitHub Releases for direct-URL hosting, and no wire-protocol changes** (reuse existing `READY` / `chrome.runtime.lastError` signals). Testing stays stdlib-first: Go `httptest.Server` + golden files for Gmail/MIME, doctest for extracted C++ logic, vitest-chrome for the extension, and Playwright persistent-context for a single E2E happy path with a mocked Gmail server.

The dominant risks are operational, not architectural: SignPath Foundation approval takes weeks (not days) and should start in parallel with installer work; the `emails` map race already documented in CONCERNS.md must be fixed before `go test -race` can land in CI; and Playwright + headed Chromium on `windows-latest` is notoriously flaky, so the E2E phase needs a reserved spike day. The "install from extension" UX has no clean competitor reference — Bitwarden, KeePassXC-Browser, and Claude-in-Chrome all ship rougher versions — which is simultaneously a differentiation opportunity and a novelty risk.

## Key Findings

### Recommended Stack

See `.planning/research/STACK.md` for full rationale and "don't use" list.

**Core technologies:**
- **Inno Setup 6.4.x** (installer) — FOSS, Pascal scripting, first-class `[Registry]` + `SignTool` directives, matches HKLM MAPI + Chrome/Edge native-messaging manifest needs. Rejected WiX (heavy), NSIS (worse uninstall cleanup), MSIX (containerization blocks the HKLM MAPI handler surface), and building an installer in Go ("reimplement UAC + SmartScreen from scratch").
- **SignPath Foundation** (code signing) — free for OSI-approved FOSS, signs via `SignPath/github-action-submit-signing-request@v1`. go-mapi meets eligibility on paper (LGPL-3.0, active, shipped v1.0.0). Azure Trusted Signing is ruled out — currently US/Canada individuals only and Marc is EU. Never self-sign.
- **GitHub Releases `latest/download/go-mapi-setup.exe`** (hosting) — free, HTTPS, CDN-backed, better SmartScreen reputation than random CDNs. No R2/S3/Netlify. Defer any `blegal.dev` redirector to v2.1.0.
- **Go stdlib testing + `httptest.Server` + golden files** — idiomatic, matches existing test style, no `testify`. `GmailClient` needs a `baseURL` field added for injection — small, isolated refactor.
- **doctest** for C++ DLL tests — lightest touch, best MinGW + CMake integration. Requires extracting message-conversion logic from `main.cpp` into `message_converter.{h,cpp}` (pure logic only; DLL glue stays untested).
- **vitest-chrome** for extension TypeScript tests — project already on Vitest, purpose-built for `chrome.*` API mocking.
- **Playwright `launchPersistentContext`** (headed) for the single E2E happy path. Chrome extensions do not load headless; headed mode on `windows-latest` is mandatory and flaky.
- **`go test -race` with `CGO_ENABLED=1`** in a dedicated Windows nightly CI job (not per-PR — 15-30× slowdown).

**Explicit "don't use" list:**
- WiX, NSIS, MSIX, InstallShield, Advanced Installer
- Self-signed certs, self-signing + "add to trust store" workflows
- Jest, `jest-chrome` (project is on Vitest), `testify`
- Real Gmail API in CI happy-path tests
- `mockgen` or other heavy mocking frameworks for Go HTTP
- GoogleTest for C++ (heavier than doctest for this scope)
- Tray icons, background services, auto-start, telemetry, crash reporters

### Expected Features

See `.planning/research/FEATURES.md` for the 7-bucket breakdown with complexity ratings.

**Must have (table stakes):**
- Extension detects missing host via `chrome.runtime.lastError` substring match on `"Specified native messaging host not found"` — nothing else in the install UX works without this
- In-popup "Install" banner with a direct download link (no GitHub redirect)
- Inno Setup installer that writes files under `%ProgramFiles%\go-mapi\`, HKLM registry keys, and native-messaging manifests for Chrome + Edge + Chromium + Brave + Vivaldi (all 5 trees) — a single UAC prompt, no per-user state
- Auto-detect when the host appears post-install (reuse existing 6s reconnect alarm, gate on `READY` message, not just port open) + success toast
- Clean uninstall that removes DLL, registry keys, native-messaging manifests, and leftover `%TEMP%\go-mapi\` files
- Signed installer via SignPath Foundation (fallback: unsigned with SmartScreen guidance copy)
- `buildFullMIME` golden-file tests (highest blast-radius gap — RFC 2822 encoding with attachments, UTF-8 subjects, boundary collisions)
- Gmail HTTP client tests via `httptest.Server`
- `go test -race` in CI (Windows nightly, after fixing the `emails` map race from CONCERNS.md)
- Playwright E2E: drop fixture JSON into `%TEMP%\go-mapi\` → real Go host → mocked Gmail → popup → success toast

**Should have (competitive differentiators):**
- Error recovery copy for SmartScreen warnings, AV false positives, admin-locked machines
- Extension TypeScript tests for `hostDetector`, `InstallPrompt`, service worker state transitions
- Extracted C++ `message_converter` with doctest smoke tests
- Installer CI smoke test (Pester 5) verifying silent install + registry + uninstall round-trip on a `windows-latest` runner

**Defer (v2.1.0+):**
- Host self-update (re-run installer is acceptable)
- `blegal.dev` download redirector
- Nightly real-Gmail API smoke test
- Edge Add-ons Store publishing (Chrome Web Store only for v2.0.0)
- Mutation testing (nice signal, out of scope for this milestone)

**Explicit anti-features (load-bearing for go-mapi's FOSS / privacy identity):**
- No tray icon
- No background service / auto-start
- No telemetry / crash reporter
- No desktop shortcut / Start Menu entry beyond what Inno Setup's default uninstall list needs
- No firewall rules
- No rating prompts / guided tours / confetti success modal / uninstall survey
- No "keep running in case you change your mind" nag on uninstall

### Architecture Approach

See `.planning/research/ARCHITECTURE.md` for full component boundaries and data flow.

The critical architectural insight is that **the native messaging wire protocol does not change**. Version-skew and reinstall detection use existing signals: `chrome.runtime.lastError` substring matching on `connectNative` failure, and the `SendReady(version)` message that the host already emits on startup. Adding new wire messages would create exactly the version-skew problems we are trying to detect.

**Major components:**
1. **`src/installer/`** (new, first-class) — Inno Setup `.iss` script, registry templates for all 5 browser trees, native-messaging manifest templates (Chrome + Edge formats), uninstall data file for MAPI default-handler restore. Not in `scripts/` — first-class source.
2. **`src/extension/src/lib/hostDetector.ts`** (new) — State machine: `UNKNOWN → PROBING → {READY | MISSING | OUTDATED | ERROR}`. Only the MISSING branch shows the install prompt. Testable in isolation with the existing `chrome.ts` mock — NOT in `service-worker.ts`.
3. **`src/extension/src/lib/hostVersion.ts`** (new) — `MIN_SUPPORTED_HOST_VERSION` constant + comparison helper. Ships with current-version = OUTDATED dead branch so v3.0.0 can activate it without a breaking change.
4. **`src/extension/src/popup/InstallPrompt.tsx`** (new) — Renders conditionally from the `HOST_STATE` broadcast. Direct download link, SmartScreen guidance copy.
5. **`src/native-host/version.go`** (new) — Version constant surfaced in the existing `READY` message.
6. **`src/native-host/main.go`** (modified) — Accept a `GOMAPI_WATCH_DIR` env var for E2E tests that need a per-test watch directory, and a `--gmail-api-base` flag for httptest injection.
7. **`src/native-host/gmail.go`** (modified) — Add `baseURL` field on `GmailClient` for `httptest.Server` injection. Small refactor.
8. **`src/interceptor/message_converter.{h,cpp}`** (new, extracted) — Pure message-conversion logic pulled out of `main.cpp` so doctest can exercise it without linking the DLL glue.
9. **`tests/e2e/`** (new) — Playwright `launchPersistentContext` tests. Three scenarios: T1 happy path (real host + mocked Gmail), T2 install-UX (MISSING → prompt → reload manifest → READY), T3 installer smoke (Pester 5, separate runner).
10. **`tests/e2e/mock-host/`** (new) — ~150 LOC mock Go host for T2 install-UX tests (no need to build + install the real DLL in CI just to test the extension UX).
11. **`.github/workflows/`** (modified + new) — Existing `build.yml` gets `-race` nightly job and extension test job. New `installer.yml` builds + smoke-tests the installer. New `e2e.yml` runs Playwright headed on `windows-latest`.

**Integration points** (existing files that change):
- `src/extension/src/background/service-worker.ts` — wire in `hostDetector`, emit `HOST_STATE` broadcast
- `src/extension/src/popup/App.tsx` — conditional `InstallPrompt` rendering
- `src/extension/src/types/messages.ts` — new `HOST_STATE` broadcast type (internal to extension, NOT native protocol)
- `src/native-host/manifests/*.json` → `*.json.tmpl` (templated so `install.ps1` and Inno Setup share one template set)
- `scripts/install.ps1` — kept as the developer path, refactored to consume the shared templates
- `package.json` scripts — new build targets for installer

**Files NOT touched:** `src/interceptor/main.cpp` (unchanged — only extracted from), `src/native-host/watcher.go`, `src/native-host/protocol.go` wire types, `src/extension/src/lib/gmail.ts`.

### Critical Pitfalls

See `.planning/research/PITFALLS.md` for the 8 workstream breakdown and post-mortem references.

1. **Only registering Chrome, not Edge/Chromium/Brave/Vivaldi** — The highest-probability "looks done" bug. Anthropic Claude Code issue #24367 is the reference post-mortem. **Prevention:** Inno Setup writes to all 5 registry trees from day one as a baseline, not a stretch goal (~10 extra `.iss` lines).
2. **SignPath Foundation approval is weeks, not days** — Manual release approval per build, and the MAPI-interception behavior will look suspicious to a reviewer without context. **Prevention:** File the application in the same phase as installer work begins; prepare a short explanation of the MAPI handler model referencing the public Chrome Web Store listing. Ship unsigned with SmartScreen guidance as a fallback.
3. **Turning on `go test -race` with a known race present** — The `emails` map race already documented in CONCERNS.md will make CI red on day one. `-race` also slows Windows CI by 15-30×. **Prevention:** Fix the `emails` map race FIRST in a dedicated plan; then split the race job into a Windows nightly (not per-PR).
4. **Native messaging error-string drift across Chrome versions** — `chrome.runtime.lastError.message` substrings have changed historically. Claude Code issue #16350 is the reference. **Prevention:** Match on stable substrings (`"not found"`, `"exited"`), log the full message, and capture real fixtures from actual Chrome runs during the E2E phase.
5. **Playwright + headed Chromium + native messaging on `windows-latest` CI** — Nobody has written a great end-to-end guide for this combination in 2026; community reports are positive-but-not-definitive. **Prevention:** Budget a reserved spike day at the start of the E2E phase. Mocked-Gmail + T1/T2/T3 separation reduces surface area.
6. **UAC context-swap when writing "per-user" state during an elevated install** — Rubberduck-VBA issue #458. **Prevention:** Go all-HKLM and `%ProgramData%\go-mapi\` — no per-user state from the installer.
7. **The coverage % trap** — Explicitly rejected in PROJECT.md, but easy to drift back into. **Prevention:** Audit with a named blast-radius priority list (`buildFullMIME` → Gmail HTTP → validator edge cases → watcher races → extension service worker). No numeric target.

## Implications for Roadmap

PROJECT.md config is `granularity: coarse` → target 3-5 phases. Based on the convergent architecture from all four research dimensions, the recommended phase structure is 4 coarse phases with maximal parallelism between Phase 2 (extension UX) and Phase 3 (installer). The roadmapper agent makes the final call.

### Phase 1: Foundation & Pre-reqs

**Rationale:** A small number of load-bearing fixes and refactors must land before any of the new work can start. None are user-visible; all unblock parallel work in later phases.
**Delivers:**
- Fix the `emails` map race from CONCERNS.md (prerequisite for `-race` CI)
- Add `version.go` constant and surface it in the existing `SendReady` message
- Add `baseURL` field to `GmailClient` for test injection
- Add `GOMAPI_WATCH_DIR` env var and `--gmail-api-base` flag to `main.go`
- Extract `message_converter.{h,cpp}` from `src/interceptor/main.cpp` (pure logic only)
- Template the native-messaging manifests (`.tmpl`) and retrofit `install.ps1` to consume them
- File SignPath Foundation application with MAPI-interception explanation — in parallel, may lag
**Addresses:** blocking prerequisites identified by Stack, Architecture, and Pitfalls research
**Avoids:** Pitfall #3 (race-on-day-one) and Pitfall #2 (SignPath late)

### Phase 2: Host Detection + Install Prompt Extension UI

**Rationale:** Architecture §5 identified this as the minimum useful slice — a visible "install me" popup is shippable in isolation as a mock UX using a placeholder download URL. Runs in parallel with Phase 3.
**Delivers:**
- `hostDetector.ts` state machine + vitest-chrome unit tests
- `hostVersion.ts` with `MIN_SUPPORTED_HOST_VERSION` constant and tests
- `HOST_STATE` internal broadcast type
- `InstallPrompt.tsx` component + vitest-chrome tests
- Wire into `service-worker.ts` and `App.tsx`
- Accelerated-polling + success-toast chain for the auto-detect reconnect
- Placeholder direct-download URL (swapped for the real URL in Phase 3)
**Uses:** vitest-chrome, existing React + React Bootstrap setup
**Implements:** Components 2-4 from the Architecture section
**Avoids:** Pitfall #4 (native messaging error strings) via substring matching + full-message logging

### Phase 3: Inno Setup Installer + Signing + Hosting

**Rationale:** Installer work is independent of Phase 2 once the template/version prerequisites from Phase 1 land. Architecture-level parallel with Phase 2 — Phase 2's placeholder URL gets swapped for the real one at integration time.
**Delivers:**
- `src/installer/go-mapi.iss` (Inno Setup 6) script
- Registry writes for all 5 browser trees (Chrome / Edge / Chromium / Brave / Vivaldi)
- Native messaging manifests from templates
- MAPI default-handler backup + restore data file
- Clean uninstall (files, registry, manifests, `%TEMP%\go-mapi\`)
- SignPath GitHub Action wiring (signs `.dll` and `.exe` before `iscc.exe`, then signs the installer `.exe` post-build)
- GitHub Releases stable `latest/download/go-mapi-setup.exe` URL
- Installer CI smoke test (Pester 5) on `windows-latest`
- Swap Phase 2's placeholder URL for the real GitHub Releases URL
**Uses:** Inno Setup 6.4.x, SignPath Foundation, GitHub Releases
**Implements:** Component 1 from the Architecture section
**Avoids:** Pitfalls #1 (Edge-missing), #2 (SignPath late), #6 (UAC context-swap)

### Phase 4: Test-Suite Completeness

**Rationale:** Depends on Phase 1 refactors (especially `GmailClient.baseURL` and `message_converter` extraction). Runs in parallel with Phase 2 and Phase 3 for the Go and C++ test work; E2E and the extension-UX tests wait for Phases 2 and 3 respectively.
**Delivers:**
- Go: `httptest.Server` tests for Gmail HTTP client
- Go: golden-file tests for `buildFullMIME` (highest blast radius — UTF-8 subjects, boundary collisions, attachment filenames with spaces)
- Go: `-race` CI job as a Windows nightly (per-PR would be too slow)
- C++: doctest tests for extracted `message_converter`, wired into CMake
- TS: vitest-chrome tests for `hostDetector`, `InstallPrompt`, and service worker state transitions (depends on Phase 2 components)
- E2E: Playwright `launchPersistentContext` happy path (T1), install-UX flow with mock host (T2), installer smoke (T3, Pester 5) — depends on Phases 2 and 3
- Reserved spike day for headed-Chromium-on-`windows-latest` flakiness investigation
- Capture real `chrome.runtime.lastError` fixture strings from E2E runs for Phase 2 tests
**Addresses:** `buildFullMIME`, Gmail HTTP client, extension TS, C++ DLL, E2E gaps — all from TESTING.md
**Avoids:** Pitfalls #5 (Playwright flakiness), #4 (error string drift), #7 (coverage % trap — uses blast-radius priority)

### Phase Ordering Rationale

- **Phase 1 is the unblocker.** Every parallelism opportunity in Phases 2-4 depends on small pre-work that must land first (race fix, version constant, `baseURL` injection, `message_converter` extract, manifest templates, SignPath application).
- **Phases 2 and 3 run in parallel.** Extension UX work uses a placeholder URL until Phase 3 completes; Architecture §5 explicitly endorses this to avoid circular build dependencies.
- **Phase 4 runs mostly in parallel with 2 and 3.** Go httptest + golden MIME + C++ doctest have no dependencies beyond Phase 1. Extension tests and E2E wait for their implementation targets.
- **Signing is async.** SignPath Foundation approval can lag weeks behind Phase 3 code work — keep the unsigned artifact path working as a fallback so the installer ships either way.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 3:** Validate that Inno Setup's post-build signing workflow plays cleanly with SignPath's "sign artifacts after build" model. Also validate SignPath approval timeline + reviewer requirements for a MAPI-interception project.
- **Phase 4:** Reserved spike day for Playwright + headed Chromium + `windows-latest` flakiness. Also confirm exact `chrome.runtime.lastError` substrings across current Chrome and Edge versions before committing to the substring match set.

Phases with standard patterns (skip research-phase):
- **Phase 1:** All fixes and refactors are small and mechanical. Skip research.
- **Phase 2:** vitest-chrome + React component testing is well-documented. Skip research.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All 4 agents converged on Inno Setup + SignPath + GitHub Releases + stdlib Go + doctest + vitest-chrome + Playwright. No tension. |
| Features | HIGH | Feature buckets are well-studied (competitor analysis: 1Password, Bitwarden, KeePassXC, Claude Code). Anti-features are non-trivial and tied to FOSS identity. |
| Architecture | HIGH | Wire protocol reuse + HKLM + new `hostDetector.ts` isolation is a clean design. Build order is unambiguous. |
| Pitfalls | HIGH | Backed by named post-mortems (Claude Code #24367, #16350; Rubberduck #458; Teleport #15995) and official docs. |

**Overall confidence:** HIGH

### Gaps to Address

- **SignPath Foundation approval timeline + MAPI-interception acceptability** — unknown until the application is filed. File early in Phase 1, not when the installer is ready. Pitfall #2.
- **HKCU vs HKLM for MAPI registration** — Features research flagged this as "LOW confidence" but Architecture + Pitfalls both confirmed HKLM is required for the MAPI handler, so the question is resolved: HKLM. Verify once during Phase 3 implementation.
- **`chrome.runtime.lastError.message` exact substrings** across current Chrome/Edge versions — capture fixtures during Phase 4 E2E runs and feed them back into Phase 2 tests.
- **Existing `emails` map race actual severity and count** — run `go test -race ./...` once at the start of Phase 1 to scope the work.
- **Edge Add-ons Store ID** for `allowed_origins` in manifests — needed only if Edge Add-ons publishing is in scope. PROJECT.md implies Chrome Web Store only for v2.0.0; confirm during Phase 3.
- **Extension manifest `"key"` pinning** for stable extension ID across dev/prod — check `src/extension/public/manifest.json` during Phase 2 and add if missing.
- **Playwright headed Chromium reliability on `windows-latest` runners** — budget the spike day in Phase 4.

## Sources

### Primary (HIGH confidence)
- `.planning/research/STACK.md` — Inno Setup, SignPath, GitHub Releases, testing stack
- `.planning/research/FEATURES.md` — feature buckets with competitor analysis
- `.planning/research/ARCHITECTURE.md` — component boundaries, data flow, build order
- `.planning/research/PITFALLS.md` — 8-workstream pitfall catalog with post-mortem references
- `.planning/codebase/ARCHITECTURE.md` — existing three-tier bridge state
- `.planning/codebase/TESTING.md` — existing test gaps
- `.planning/codebase/CONCERNS.md` — existing known issues (including the `emails` map race)
- Chrome for Developers — Native Messaging official docs
- Microsoft Learn — Native Messaging in Edge
- Inno Setup official docs — `[Registry]` and `SignTool` sections
- SignPath Foundation terms and GitHub Action docs
- Playwright Chrome Extensions official docs

### Secondary (MEDIUM confidence)
- Claude Code issue #16350 — native host dies when service worker idles
- Claude Code issue #24367 — Edge native messaging not registered
- Rubberduck-VBA issue #458 — HKCU wrong-profile post-mortem
- Gravitational Teleport issue #15995 — SmartScreen blocking installer
- SQLiteBrowser — SignPath Foundation case study
- browserpass-native — cross-browser registration reference
- `actions/runner-images` #7320 — Windows runner performance
- Bitfield Consulting — slow / flaky / failing Go tests

### Tertiary (LOW confidence — validate during implementation)
- Windows 11 25H2 SmartScreen reputation threshold (cited 15k downloads number, single-sourced) — validate before relying on it in copy
- Exact Playwright + headed Chromium + native messaging flakiness profile on `windows-latest` in 2026 — community folklore, no definitive guide

---
*Research completed: 2026-04-10*
*Ready for roadmap: yes*
