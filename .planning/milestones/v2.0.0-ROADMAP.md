# Roadmap: go-mapi v2.0.0

**Created:** 2026-04-10
**Granularity:** coarse
**Milestone:** v2.0.0 — Installer UX + Test-Suite Completeness
**Core Value:** A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.

## Phases

- [x] **Phase 1: Foundation & SignPath Application** - Mechanical refactors that unblock all parallel work, plus filing the SignPath OSS application early
 (completed 2026-04-10)
- [x] **Phase 2: Extension Install UX** - In-popup install prompt and host-state machine using a placeholder download URL (completed 2026-04-10)
- [x] **Phase 3: Inno Setup Installer + Signing + Distribution** - Single-click signed Windows installer hosted on GitHub Releases, with the extension wired to the real URL (completed 2026-04-10)
- [x] **Phase 4: Test-Suite Completeness + E2E** - Risk-based test gap fill across Go, C++, TypeScript, plus a Playwright happy-path E2E (completed 2026-04-10)
- [ ] **Phase 5: Release Cut** - CI green-light → tag push → GitHub Releases publish → hardened Windows Sandbox local repro → manual UAT → README rewrite. Closes v2.0.0 "source complete → actually shipped". Ships unsigned; SignPath-signed re-cut lives in v2.0.1.

## Phase Details

### Phase 1: Foundation & SignPath Application
**Goal**: Land the small, mechanical refactors and async paperwork that everything else in v2.0.0 depends on
**Depends on**: Nothing (first phase)
**Requirements**: FOUND-01, FOUND-02, FOUND-03, FOUND-04, FOUND-05, FOUND-06, SIGN-01
**Success Criteria** (what must be TRUE):
  1. `go test -race ./...` runs clean locally on Windows against the native host (the `emails` map race from CONCERNS.md is gone)
  2. The native host emits its version in the existing `READY` message and exposes `GOMAPI_WATCH_DIR` + `--gmail-api-base` so tests and E2E can run without touching `%TEMP%\go-mapi\` or the real Gmail API
  3. `GmailClient` accepts a `baseURL` so a future `httptest.Server` can be injected without monkey-patching
  4. C++ message-conversion logic lives in `src/interceptor/message_converter.{h,cpp}` and is link-compatible with both the DLL and a future doctest binary
  5. Both `scripts/install.ps1` and the future Inno Setup installer consume the same `.tmpl` native-messaging manifests (single source of truth, no drift)
  6. The SignPath Foundation OSS application is filed with a written explanation of the MAPI-interception behavior and a link to the public Chrome Web Store listing
**Plans**: 8 plans
Plans:
- [ ] 01-PLAN-01-version-constant-and-ready-message.md � Extract Version into version.go and add additive hostVersion field to READY message (FOUND-02)
- [ ] 01-PLAN-02-watcher-race-fix.md � Surgical fix for emails map race so go test -race runs clean (FOUND-01)
- [ ] 01-PLAN-03-gmail-client-baseurl-injection.md � Add baseURL field to GmailClient with NewGmailClientWithBase constructor (FOUND-03)
- [ ] 01-PLAN-04-env-var-and-cli-flag.md � GOMAPI_WATCH_DIR env var and --gmail-api-base / --watch-dir CLI flags with CLI > env > default precedence (FOUND-04)
- [ ] 01-PLAN-05-cpp-message-converter-extract.md � Extract pure conversion logic into message_converter.{h,cpp} as an OBJECT library (FOUND-05)
- [ ] 01-PLAN-06-manifest-templates.md � Chrome/Edge manifest .tmpl files + install.ps1 template rendering (FOUND-06)
- [ ] 01-PLAN-07-signpath-application-draft.md � Draft SignPath Foundation OSS application text (SIGN-01 half 1)
- [ ] 01-PLAN-08-signpath-filing-confirmation.md � Human-verify checkpoint for Marc filing the application (SIGN-01 half 2)

### Phase 2: Extension Install UX
**Goal**: A user opening the extension popup on a machine without the host sees a clear in-popup install banner with a direct download link, and the popup auto-detects the host appearing afterwards
**Depends on**: Phase 1 (needs FOUND-02 version constant in `READY` message)
**Requirements**: EXT-01, EXT-02, EXT-03, EXT-04, EXT-05, EXT-06
**Success Criteria** (what must be TRUE):
  1. With no host installed, opening the extension popup shows an `InstallPrompt` with a direct download link and SmartScreen guidance copy (placeholder URL during this phase, real URL swapped in Phase 3)
  2. Once the host appears at runtime, the popup transitions from `MISSING` to `READY` within one reconnect-alarm cycle and shows a one-time success toast — no manual reload required
  3. The host-state machine (`UNKNOWN → PROBING → READY | MISSING | OUTDATED | ERROR`) drives the popup render, classifies the `"not found"` substring as `MISSING`, and logs the full `chrome.runtime.lastError.message` for forward compatibility
  4. The `OUTDATED` branch ships as a dead branch (current host version equals `MIN_SUPPORTED_HOST_VERSION`) ready for v3.0.0 activation without a wire-protocol change
  5. No new native-messaging wire types were added — all new state lives in the internal `HOST_STATE` extension broadcast
**Plans**: TBD
**UI hint**: yes

### Phase 3: Inno Setup Installer + Signing + Distribution
**Goal**: A non-technical Windows user downloads a single signed `.exe` from a stable URL, clicks through one UAC prompt, and has go-mapi fully registered for all five Chromium-family browsers
**Depends on**: Phase 1 (needs FOUND-06 manifest templates and FOUND-02 version constant). Runs in parallel with Phase 2.
**Requirements**: INST-01, INST-02, INST-03, INST-04, INST-05, INST-06, INST-07, SIGN-02, SIGN-03, SIGN-04, SIGN-05, EXT-07
**Success Criteria** (what must be TRUE):
  1. A fresh `windows-latest` runner can install go-mapi end-to-end via the built `.exe` with a single UAC prompt, and the Pester 5 smoke test verifies registry state, files present, and a clean uninstall round-trip
  2. After install, a "Send to Mail recipient" action from any Win32 app surfaces in the extension popup of any of Chrome, Edge, Chromium, Brave, or Vivaldi (all five browser registry trees written from day one — not stretch-goaled)
  3. The installer is published to GitHub Releases at the stable `https://github.com/<owner>/<repo>/releases/latest/download/go-mapi-setup.exe` URL, and the extension's `InstallPrompt` links to that exact URL (EXT-07 swap landed)
  4. Uninstall removes the DLL, native host binary, all five browser registry trees, the MAPI handler registration, leftover `%TEMP%\go-mapi\` files, and restores the prior default Mail client from the backup file written at install time
  5. The signed pipeline works when SignPath approval is in place (DLL + `.exe` signed before `iscc.exe`, installer signed post-build); the unsigned fallback path remains green so the installer ships either way; the v2.0.0 release notes include SmartScreen guidance for the unsigned fallback case
**Plans**: TBD
**Research flag**: SignPath GitHub Action + Inno Setup `SignTool` integration (validate the "sign before iscc, sign installer after" handoff); SignPath approval timeline + reviewer requirements for a MAPI-interception project

### Phase 4: Test-Suite Completeness + E2E
**Goal**: A regression in any of the highest-blast-radius areas (`buildFullMIME`, Gmail HTTP, host-detector state machine, C++ message conversion, install UX) is caught by CI before it ships
**Depends on**: Phase 1 (FOUND-03 baseURL, FOUND-04 env/flag injection, FOUND-05 message_converter extraction), Phase 2 (EXT components for TSTEST-02/04/05 and E2E-04), Phase 3 (installer for E2E install-flow validation)
**Requirements**: GOTEST-01, GOTEST-02, GOTEST-03, GOTEST-04, CPPTEST-01, CPPTEST-02, CPPTEST-03, TSTEST-01, TSTEST-02, TSTEST-03, TSTEST-04, TSTEST-05, E2E-01, E2E-02, E2E-03, E2E-04, E2E-05, E2E-06
**Success Criteria** (what must be TRUE):
  1. `buildFullMIME` and the Gmail HTTP client have golden-file and `httptest.Server` tests covering UTF-8 subjects, attachment filenames with spaces and non-ASCII characters, multipart boundary collisions, long bodies, empty bodies, success, 4xx auth errors, and network failures
  2. CI catches a deliberately introduced race in the watcher: `go test -race ./...` runs as a Windows nightly job with `CGO_ENABLED=1`, while the per-PR job stays fast without `-race`
  3. The extracted C++ `message_converter` has doctest tests covering ANSI/Wide paths, all recipient prefix variants (`SMTP:` / `smtp:` / `MAILTO:` / `mailto:` / plain), null/empty fields, and UTF-8 bodies, all running in CI on `windows-latest`
  4. `hostDetector`, `hostVersion`, `InstallPrompt`, and the service worker `HOST_STATE` broadcast have vitest-chrome unit/component tests using real `chrome.runtime.lastError` fixture strings captured during E2E runs
  5. A Playwright `launchPersistentContext` happy-path test on `windows-latest` exercises: drop fixture JSON into a per-test watch dir → real Go host processes it → popup shows the email → click Save as Draft → mock Gmail receives the draft → success notification appears
  6. A second Playwright test exercises the install UX: launch Chromium with no manifest registered → assert `InstallPrompt` appears → write the manifest pointing at a mock host binary → fire Retry → assert state transitions to `READY` and the toast appears
  7. A risk-based test audit punch list exists, judged-load-bearing entries are filled, and explicitly deferred low-risk gaps are documented with reasoning (no numeric coverage gate)
**Plans**: TBD
**Research flag**: Reserved spike day for Playwright + headed Chromium + native messaging flakiness on `windows-latest` (Pitfall #5); confirm exact `chrome.runtime.lastError` substrings across current Chrome and Edge versions before locking in TSTEST-02 fixtures

### Phase 5: Release Cut
**Goal**: A real user can download `go-mapi-setup.exe` from the v2.0.0 GitHub Releases page, install it on a fresh Windows box, and successfully create a Gmail draft via a "Send to Mail recipient" action. Source-complete → actually shipped.
**Depends on**: Phases 1-4 (all source artifacts complete and merged into `develop`)
**Requirements**: REL-01, REL-02, REL-03, REL-04, REL-05, REL-06, REL-07
**Success Criteria** (what must be TRUE):
  1. All three `windows-latest` CI workflows have been run at least once and are green: `installer-smoke.yml` (Pester round-trip), `e2e.yml` (Playwright happy path + install UX), `go-race-nightly.yml` (`-race` on amd64). Any first-run flakes or failures are fixed or explicitly documented.
  2. The existing `tests/sandbox/` Windows Sandbox harness is hardened into a real local repro path — committed `.wsb` config, `pwsh tests/sandbox/run-sandbox-test.ps1 -FullTest` entry point, and `tests/sandbox/README.md` documenting prerequisites (Windows 11 24H2+, `wsb` CLI) and expected runtime. Enables verifying install → E2E locally without touching the host.
  3. `README.md` install instructions are rewritten for the real v2.0.0 distribution flow: download from GitHub Releases, SmartScreen click-through for the unsigned fallback, single UAC elevation, uninstall pointer.
  4. PHASE-4-FINDING-02 (pre-existing `-Wcomment` warning in `src/interceptor/json_writer.h:36`) is closed with a one-line fix bundled into whatever Phase 5 commit touches the interceptor build output.
  5. The `v2.0.0` git tag is pushed, `installer-release.yml` runs to completion, and `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` returns 200 with a non-empty `Content-Length` that matches what `InstallPrompt.tsx` links to.
  6. Manual end-to-end UAT passes on a real Windows box (marcwin or a Windows Sandbox from REL-02): download the published installer, install via UAC, load the unpacked extension, observe `MISSING → READY` + success toast, trigger a "Send to Mail recipient" from a Win32 app, confirm a Gmail draft appears. Results captured in `05-UAT.md`.
  7. After UAT passes, the v2.0.0 milestone is re-archived via `/gsd:complete-milestone v2.0.0` — MILESTONES.md entry reflects the runtime-verified state (not just source-complete), the tag already exists on `develop`, and STATE.md transitions to `milestone_complete`.
**Plans**: 4 plans
Plans:
- [x] 05-01-ci-trigger-docs-and-json-writer-fix-PLAN.md — json_writer.h -Wcomment fix + MANUAL-STEPS.md REL-01 CI trigger runbook (REL-01, REL-04)
- [x] 05-02-sandbox-harness-hardening-PLAN.md — tests/sandbox .wsb + install-and-verify.ps1 + FullTest + README (REL-02)
- [x] 05-03-readme-rewrite-PLAN.md — README.md end-user install flow rewrite (REL-03)
- [x] 05-04-release-uat-and-milestone-rearchive-PLAN.md — REL-05/06/07 runbook sections + 05-UAT.md checklist (REL-05, REL-06, REL-07)
**Notes**: Phase 5 is mostly Marc-owned manual work (CI triggering needs `gh` auth + approval, UAT needs a real Windows box). Scaffolded during the interim milestone audit when it became clear "source complete" ≠ "shipped".

## Phase Ordering Rationale

- **Phase 1 is the unblocker.** Every parallelism opportunity in Phases 2-4 depends on small pre-work landing first: race fix (unblocks GOTEST-03), version constant (unblocks EXT host-state probing), `baseURL` injection (unblocks GOTEST-01), env/flag injection (unblocks E2E-02/03), `message_converter` extract (unblocks CPPTEST-02), manifest templates (unblocks INST-03), and the SignPath application (unblocks SIGN-02 weeks later).
- **Phases 2 and 3 run in parallel.** Extension UX uses a placeholder URL until Phase 3 delivers the real one — `EXT-07` is the swap and lives in Phase 3 because the URL only exists when the installer is published. Architecture research §5 explicitly endorses this slicing to avoid a circular build dependency.
- **Phase 4 waits for Phases 2 and 3 to settle for the E2E and TS pieces.** TSTEST-02/04/05 test EXT components, E2E-04 needs the install-UX flow, and E2E-06 captures fixtures that feed back into TSTEST-02. Go and C++ test work could in principle start at the end of Phase 1, but for coarse granularity they're consolidated here so the milestone has one "test completeness" boundary.
- **Signing is async.** SignPath Foundation approval can lag weeks behind Phase 3 code work. SIGN-01 is filed in Phase 1 to start the clock; SIGN-02..05 ship in Phase 3 with SIGN-03 (unsigned fallback) gating release if approval hasn't landed.
- **GOTEST-03 (`-race` in CI) is in Phase 4, not Phase 1.** FOUND-01 fixes the known race in Phase 1; turning on `-race` in CI is then a Phase 4 deliverable bundled with the rest of the test work.

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation & SignPath Application | 8/8 | Complete   | 2026-04-10 |
| 2. Extension Install UX | 4/4 | Complete   | 2026-04-10 |
| 3. Inno Setup Installer + Signing + Distribution | 4/4 | Complete   | 2026-04-10 |
| 4. Test-Suite Completeness + E2E | 4/4 | Complete   | 2026-04-10 |
| 5. Release Cut | 0/4 | Not started | - |

## Coverage

- v1 requirements: 50 total (43 original + 7 REL-* added at Phase 5 insertion)
- Mapped to phases: 50 ✓
- Unmapped: 0
- Duplicates: 0

---
*Roadmap created: 2026-04-10*
