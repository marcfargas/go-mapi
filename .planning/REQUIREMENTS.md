# Requirements: go-mapi v2.0.0

**Defined:** 2026-04-10
**Core Value:** A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.

## v1 Requirements

Requirements for the v2.0.0 release. Grouped by the seven workstreams identified in research. Each maps to exactly one roadmap phase.

### Foundation (pre-requisite refactors)

These are small, mechanical changes that unblock the parallel work in later phases. None are user-visible.

- [ ] **FOUND-01**: The existing `emails` map race condition documented in `.planning/codebase/CONCERNS.md` is fixed and `go test -race ./...` runs clean locally
- [x] **FOUND-02**: The native host exports a `Version` constant from `src/native-host/version.go` and the existing `SendReady` message carries this version field to the extension
- [x] **FOUND-03**: `GmailClient` accepts a `baseURL` field so tests can point it at an `httptest.Server` instead of `https://gmail.googleapis.com`
- [ ] **FOUND-04**: The native host accepts a `GOMAPI_WATCH_DIR` environment variable and a `--gmail-api-base` CLI flag so integration and E2E tests can run without touching the real `%TEMP%\go-mapi\` or the real Gmail API
- [x] **FOUND-05**: Pure message-conversion logic is extracted from `src/interceptor/main.cpp` into `src/interceptor/message_converter.{h,cpp}` (DLL glue stays in `main.cpp` and remains untested)
- [x] **FOUND-06**: The Chrome and Edge native-messaging manifests in `src/native-host/manifests/` are converted to `.tmpl` files with placeholders for the host executable path and extension IDs, and `scripts/install.ps1` is refactored to consume the same templates as the future installer

### Extension Install UX (EXT)

- [ ] **EXT-01**: A new `src/extension/src/lib/hostDetector.ts` module implements a state machine `UNKNOWN → PROBING → {READY | MISSING | OUTDATED | ERROR}` driven by `chrome.runtime.connectNative` results and `chrome.runtime.lastError`
- [ ] **EXT-02**: The detector classifies the `"Specified native messaging host not found"` substring as the `MISSING` state and logs the full error message for forward compatibility
- [ ] **EXT-03**: A new `src/extension/src/lib/hostVersion.ts` module defines a `MIN_SUPPORTED_HOST_VERSION` constant and a version comparison helper; the current v2.0.0 host version is set to equal the minimum so the `OUTDATED` branch ships as a dead branch ready for v3.0.0 activation
- [ ] **EXT-04**: The service worker broadcasts an internal `HOST_STATE` message whenever the detector's state changes, and the popup renders based on that state (this broadcast is internal to the extension only — the native-messaging wire protocol is not extended)
- [ ] **EXT-05**: A new `src/extension/src/popup/InstallPrompt.tsx` component renders when the state is `MISSING`, showing a direct download link, short SmartScreen guidance copy, and no GitHub redirect
- [ ] **EXT-06**: The popup auto-detects when the host appears after install by reusing the existing 6-second reconnect alarm, gated on an actual `READY` message (not just a successful port open), and shows a one-time success toast on the `MISSING → READY` transition
- [ ] **EXT-07**: When the real installer URL exists at the end of Phase 3, the placeholder download URL in `InstallPrompt.tsx` is swapped for the stable GitHub Releases `latest/download/go-mapi-setup.exe` URL

### Installer (INST)

- [ ] **INST-01**: A first-class `src/installer/` directory contains an Inno Setup 6 script (`go-mapi.iss`) that builds a single Windows installer executable
- [ ] **INST-02**: The installer copies binaries to `%ProgramFiles%\go-mapi\` and registers the MAPI handler at `HKLM:\SOFTWARE\Clients\Mail\go-mapi`
- [ ] **INST-03**: The installer writes native-messaging manifest registry entries for all five Chromium-family browsers: Chrome, Edge, Chromium, Brave, and Vivaldi (one shared manifest file, five registry trees)
- [ ] **INST-04**: The installer runs with a single UAC elevation prompt and writes no per-user state (all state under HKLM and `%ProgramData%\go-mapi\`)
- [ ] **INST-05**: Before overwriting the default Mail client registration, the installer backs up the prior handler identity to `%ProgramData%\go-mapi\uninst\previous-mail-client.json`
- [ ] **INST-06**: The installer's uninstall flow removes the DLL, native host binary, all five browser registry trees, the MAPI handler registration, and any leftover files in `%TEMP%\go-mapi\`, and restores the previous default Mail client from the backup file
- [ ] **INST-07**: A Pester 5 smoke test runs on a fresh `windows-latest` GitHub Actions runner: silent install → verify registry state → verify files present → silent uninstall → verify all state removed

### Signing + Distribution (SIGN)

- [ ] **SIGN-01**: An application to the SignPath Foundation OSS program is filed with a short explanation of the MAPI-interception behavior and a link to the public Chrome Web Store listing (application is filed in Phase 1 because approval takes weeks)
- [ ] **SIGN-02**: The CI pipeline invokes `SignPath/github-action-submit-signing-request@v1` to sign the DLL and native host executable BEFORE running `iscc.exe`, and signs the installer `.exe` as a final post-build step
- [ ] **SIGN-03**: A fallback unsigned build path remains working so the installer can ship even if SignPath approval lags the code work
- [ ] **SIGN-04**: The installer is published to GitHub Releases with a stable `https://github.com/<owner>/<repo>/releases/latest/download/go-mapi-setup.exe` URL that the extension's `InstallPrompt` links to
- [ ] **SIGN-05**: The GitHub Releases page for v2.0.0 includes SmartScreen guidance in the release notes (steps to click through "More info" → "Run anyway" in the unsigned fallback case)

### Go Test Completeness (GOTEST)

- [ ] **GOTEST-01**: The Gmail HTTP client in `src/native-host/gmail.go` has tests that use `httptest.Server` via the `GmailClient.baseURL` injection point, covering success, 4xx auth errors, 5xx retries (if any), and network failure paths
- [ ] **GOTEST-02**: The `buildFullMIME()` function has golden-file tests that cover RFC 2822 encoding edge cases: UTF-8 subjects, attachment filenames with spaces and non-ASCII characters, multipart boundary collision resistance, long bodies, and empty bodies
- [ ] **GOTEST-03**: The GitHub Actions workflow runs `go test -race ./...` as a dedicated Windows nightly job (not per-PR) with `CGO_ENABLED=1`; the per-PR job continues running without `-race` to keep the PR feedback loop fast
- [ ] **GOTEST-04**: A risk-based test audit produces a short punch list of remaining untested code (logging helpers, validator edge cases, watcher retry paths) and any entries judged load-bearing are filled; low-risk gaps are explicitly deferred with reasoning

### C++ Test Completeness (CPPTEST)

- [ ] **CPPTEST-01**: The doctest header-only test framework is added to the interceptor build under `src/interceptor/tests/` and wired into CMake as an optional `BUILD_TESTS=ON` target
- [ ] **CPPTEST-02**: The extracted `message_converter` from FOUND-05 has doctest tests covering ANSI and Wide conversion paths, recipient address normalization (SMTP: / smtp: / MAILTO: / mailto: / plain), null/empty field handling, and UTF-8 body content
- [ ] **CPPTEST-03**: CI builds and runs the C++ tests on `windows-latest` as part of the existing `build-interceptor` job

### TypeScript / Extension Test Completeness (TSTEST)

- [ ] **TSTEST-01**: `vitest-chrome` is added to the extension as a devDependency and configured in `vitest.config.ts` so tests can mock `chrome.*` APIs and the native-messaging port
- [ ] **TSTEST-02**: `hostDetector.ts` has unit tests covering every state transition, including the exact substring matches from EXT-02 against real fixture strings captured during E2E runs
- [ ] **TSTEST-03**: `hostVersion.ts` has unit tests for the comparison helper, including the dead-branch case (current version equals minimum)
- [ ] **TSTEST-04**: `InstallPrompt.tsx` has component tests via `@testing-library/react` covering the MISSING state render, the download link click handler, and the SmartScreen guidance copy
- [ ] **TSTEST-05**: The service worker's `HOST_STATE` broadcast logic has tests covering the `MISSING → READY` success-toast path and the reconnect-alarm gating logic from EXT-06

### End-to-End Tests (E2E)

- [ ] **E2E-01**: Playwright is configured with `launchPersistentContext` and headed Chromium, running on `windows-latest` in a dedicated GitHub Actions workflow (`e2e.yml`)
- [ ] **E2E-02**: A mock Gmail server (stdlib Go `httptest.Server`-based) is added under `tests/e2e/mock-gmail/` and the E2E tests inject it via the `--gmail-api-base` flag from FOUND-04
- [ ] **E2E-03**: T1 happy-path test: drop a fixture JSON file into a per-test watch directory (via `GOMAPI_WATCH_DIR`) → real Go native host processes it → extension popup shows the email → click "Save as Draft" → mock Gmail receives the draft request → popup shows success notification
- [ ] **E2E-04**: T2 install-UX test: launch Chromium with no native-messaging manifest registered → assert `InstallPrompt` appears in the popup → programmatically write the manifest pointing at a small `tests/e2e/mock-host/` binary → fire a "Retry" action → assert the state transitions to `READY` and the success toast appears
- [ ] **E2E-05**: A reserved spike day investigates Playwright + headed Chromium + native messaging flakiness on `windows-latest` and documents stable wait patterns, retry strategy, and any runner-image workarounds
- [ ] **E2E-06**: Real `chrome.runtime.lastError.message` strings are captured from the E2E runs and committed as fixtures under `src/extension/src/__fixtures__/chrome-errors.ts`, consumed by the TSTEST-02 tests

## v2 Requirements

Acknowledged but deferred. Not in the v2.0.0 roadmap.

### Host Self-Update

- **UPDATE-01**: Host checks for new versions on startup and prompts the user via the extension popup
- **UPDATE-02**: Host downloads and replaces itself without re-running the installer

### Expanded Distribution

- **DIST-01**: Installer is mirrored at a stable `blegal.dev` redirect URL for cases where GitHub Releases is blocked
- **DIST-02**: Extension is published to the Edge Add-ons Store (currently Chrome Web Store only)

### Nightly Real-API Smoke Test

- **SMOKE-01**: A nightly CI job runs the E2E happy path against the real Gmail API (gated on a dedicated test Google account's OAuth credentials) as a reality check separate from the per-PR mocked tests

### Handshake Upgrade Activation

- **HAND-01**: Bump `MIN_SUPPORTED_HOST_VERSION` in the extension to activate the `OUTDATED` state dead branch, surfacing an "upgrade the host" prompt when the extension auto-updates ahead of the host

## Out of Scope

Explicitly excluded for v2.0.0. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Outlook / Microsoft 365 support | Deferred to a future milestone; Gmail-first is the current focus |
| Multi-account Gmail (pick which account to draft in) | Deferred to a future milestone |
| SMTP / non-Gmail provider support | Deferred to a future milestone |
| Queue management UI (bulk actions, filtering, search) | Deferred to a future milestone |
| macOS / Linux support | MAPI is Windows-only |
| Mobile apps | Web/desktop only |
| 80% line-coverage gate or similar numeric target | Rejected in favor of risk-based blast-radius gap filling |
| Mutation testing | Nice signal, out of scope for this milestone |
| Tray icon / background service / auto-start | Anti-feature — contradicts go-mapi's privacy-first FOSS identity |
| Telemetry / crash reporting | Anti-feature — privacy-first |
| Desktop shortcut / Start Menu entry beyond Inno Setup default | Anti-feature — noise |
| Rating prompts / guided tours / confetti / uninstall survey | Anti-feature — noise |
| Firewall rule configuration | Not needed; only outbound HTTPS to Gmail API |
| Self-signed certs or "add to trust store" workflows | Worse than unsigned with SmartScreen guidance |
| WiX / NSIS / MSIX / InstallShield / Advanced Installer | Inno Setup is the right tool for this stack (see STACK.md rationale) |
| Jest / jest-chrome / testify / mockgen | Keep the existing Vitest + Go stdlib test style |
| Real Gmail API in per-PR E2E | Too flaky; mock via `httptest`. Nightly real-API smoke is v2.1.0 |
| Blegal.dev download redirector | GitHub Releases direct URL is sufficient for v2.0.0 |
| Edge Add-ons Store publishing | Chrome Web Store only for v2.0.0 |
| Azure Trusted Signing | EU individuals not eligible; SignPath Foundation is the path |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| FOUND-01 | Phase 1 | Planned |
| FOUND-02 | Phase 1 | Planned |
| FOUND-03 | Phase 1 | Planned |
| FOUND-04 | Phase 1 | Planned |
| FOUND-05 | Phase 1 | Planned |
| FOUND-06 | Phase 1 | Planned |
| EXT-01 | Phase 2 | Planned |
| EXT-02 | Phase 2 | Planned |
| EXT-03 | Phase 2 | Planned |
| EXT-04 | Phase 2 | Planned |
| EXT-05 | Phase 2 | Planned |
| EXT-06 | Phase 2 | Planned |
| EXT-07 | Phase 3 | Planned |
| INST-01 | Phase 3 | Planned |
| INST-02 | Phase 3 | Planned |
| INST-03 | Phase 3 | Planned |
| INST-04 | Phase 3 | Planned |
| INST-05 | Phase 3 | Planned |
| INST-06 | Phase 3 | Planned |
| INST-07 | Phase 3 | Planned |
| SIGN-01 | Phase 1 | Planned |
| SIGN-02 | Phase 3 | Planned |
| SIGN-03 | Phase 3 | Planned |
| SIGN-04 | Phase 3 | Planned |
| SIGN-05 | Phase 3 | Planned |
| GOTEST-01 | Phase 4 | Planned |
| GOTEST-02 | Phase 4 | Planned |
| GOTEST-03 | Phase 4 | Planned |
| GOTEST-04 | Phase 4 | Planned |
| CPPTEST-01 | Phase 4 | Planned |
| CPPTEST-02 | Phase 4 | Planned |
| CPPTEST-03 | Phase 4 | Planned |
| TSTEST-01 | Phase 4 | Planned |
| TSTEST-02 | Phase 4 | Planned |
| TSTEST-03 | Phase 4 | Planned |
| TSTEST-04 | Phase 4 | Planned |
| TSTEST-05 | Phase 4 | Planned |
| E2E-01 | Phase 4 | Planned |
| E2E-02 | Phase 4 | Planned |
| E2E-03 | Phase 4 | Planned |
| E2E-04 | Phase 4 | Planned |
| E2E-05 | Phase 4 | Planned |
| E2E-06 | Phase 4 | Planned |

**Coverage:**
- v1 requirements: 43 total
- Mapped to phases: 43 ✓
- Unmapped: 0

---
*Requirements defined: 2026-04-10*
*Last updated: 2026-04-10 after roadmap creation (traceability filled)*
