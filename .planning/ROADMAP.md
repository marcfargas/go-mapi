# Roadmap: go-mapi

## Milestones

- ✅ **v2.0.0 Installer UX + Test-Suite Completeness** - Phases 1-5 (shipped 2026-04-12)
- 🚧 **v2.1.0 Release Pipeline** - Phases 6-9 (in progress)

## Phases

<details>
<summary>✅ v2.0.0 Installer UX + Test-Suite Completeness (Phases 1-5) - SHIPPED 2026-04-12</summary>

- [x] **Phase 1: Foundation & SignPath Application** - Mechanical refactors that unblock all parallel work, plus filing the SignPath OSS application early (completed 2026-04-10)
- [x] **Phase 2: Extension Install UX** - In-popup install prompt and host-state machine using a placeholder download URL (completed 2026-04-10)
- [x] **Phase 3: Inno Setup Installer + Signing + Distribution** - Single-click signed Windows installer hosted on GitHub Releases, with the extension wired to the real URL (completed 2026-04-10)
- [x] **Phase 4: Test-Suite Completeness + E2E** - Risk-based test gap fill across Go, C++, TypeScript, plus a Playwright happy-path E2E (completed 2026-04-10)
- [x] **Phase 5: Release Cut** - CI green-light → tag push → GitHub Releases publish → hardened Windows Sandbox local repro → manual UAT → README rewrite (completed 2026-04-12)

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
- [x] 01-PLAN-01-version-constant-and-ready-message.md
- [x] 01-PLAN-02-watcher-race-fix.md
- [x] 01-PLAN-03-gmail-client-baseurl-injection.md
- [x] 01-PLAN-04-env-var-and-cli-flag.md
- [x] 01-PLAN-05-cpp-message-converter-extract.md
- [x] 01-PLAN-06-manifest-templates.md
- [x] 01-PLAN-07-signpath-application-draft.md
- [x] 01-PLAN-08-signpath-filing-confirmation.md

### Phase 2: Extension Install UX
**Goal**: A user opening the extension popup on a machine without the host sees a clear in-popup install banner with a direct download link, and the popup auto-detects the host appearing afterwards
**Depends on**: Phase 1
**Requirements**: EXT-01, EXT-02, EXT-03, EXT-04, EXT-05, EXT-06
**Success Criteria** (what must be TRUE):
  1. With no host installed, opening the extension popup shows an `InstallPrompt` with a direct download link and SmartScreen guidance copy
  2. Once the host appears at runtime, the popup transitions from `MISSING` to `READY` within one reconnect-alarm cycle and shows a one-time success toast
  3. The host-state machine (`UNKNOWN → PROBING → READY | MISSING | OUTDATED | ERROR`) drives the popup render
  4. The `OUTDATED` branch ships as a dead branch ready for future activation without a wire-protocol change
  5. No new native-messaging wire types were added
**Plans**: 4 plans
**UI hint**: yes

### Phase 3: Inno Setup Installer + Signing + Distribution
**Goal**: A non-technical Windows user downloads a single signed `.exe` from a stable URL, clicks through one UAC prompt, and has go-mapi fully registered for all five Chromium-family browsers
**Depends on**: Phase 1
**Requirements**: INST-01, INST-02, INST-03, INST-04, INST-05, INST-06, INST-07, SIGN-02, SIGN-03, SIGN-04, SIGN-05, EXT-07
**Success Criteria** (what must be TRUE):
  1. A fresh `windows-latest` runner can install go-mapi end-to-end via the built `.exe` with a single UAC prompt, and the Pester 5 smoke test verifies registry state, files present, and a clean uninstall round-trip
  2. After install, a "Send to Mail recipient" action from any Win32 app surfaces in the extension popup of Chrome, Edge, Chromium, Brave, or Vivaldi
  3. The installer is published to GitHub Releases at the stable `releases/latest/download/go-mapi-setup.exe` URL
  4. Uninstall removes the DLL, native host binary, all five browser registry trees, the MAPI handler registration, and leftover `%TEMP%\go-mapi\` files
  5. The signed pipeline works when SignPath approval is in place; the unsigned fallback path remains green
**Plans**: 4 plans

### Phase 4: Test-Suite Completeness + E2E
**Goal**: A regression in any of the highest-blast-radius areas is caught by CI before it ships
**Depends on**: Phases 1-3
**Requirements**: GOTEST-01, GOTEST-02, GOTEST-03, GOTEST-04, CPPTEST-01, CPPTEST-02, CPPTEST-03, TSTEST-01, TSTEST-02, TSTEST-03, TSTEST-04, TSTEST-05, E2E-01, E2E-02, E2E-03, E2E-04, E2E-05, E2E-06
**Success Criteria** (what must be TRUE):
  1. `buildFullMIME` and the Gmail HTTP client have golden-file and `httptest.Server` tests covering UTF-8 subjects, attachments, boundary collisions, auth errors, and network failures
  2. CI catches a deliberately introduced race: `go test -race ./...` runs as a Windows nightly job
  3. The extracted C++ `message_converter` has doctest tests covering ANSI/Wide paths, all recipient prefix variants, null/empty fields, and UTF-8 bodies
  4. `hostDetector`, `hostVersion`, `InstallPrompt`, and the service worker `HOST_STATE` broadcast have vitest-chrome unit/component tests
  5. A Playwright happy-path test on `windows-latest` exercises the full email-to-draft flow
**Plans**: 4 plans

### Phase 5: Release Cut
**Goal**: A real user can download `go-mapi-setup.exe` from the v2.0.0 GitHub Releases page, install it, and successfully create a Gmail draft via a "Send to Mail recipient" action
**Depends on**: Phases 1-4
**Requirements**: REL-01, REL-02, REL-03, REL-04, REL-05, REL-06, REL-07
**Success Criteria** (what must be TRUE):
  1. All three `windows-latest` CI workflows have been run at least once and are green
  2. The Windows Sandbox harness is hardened into a real local repro path with committed `.wsb` config
  3. `README.md` install instructions are rewritten for the real v2.0.0 distribution flow
  4. The `v2.0.0` git tag is pushed and `releases/latest/download/go-mapi-setup.exe` returns 200
  5. Manual end-to-end UAT passes on a real Windows box and results are captured in `05-UAT.md`
**Plans**: 4 plans

Plans:
- [x] 05-01-ci-trigger-docs-and-json-writer-fix-PLAN.md
- [x] 05-02-sandbox-harness-hardening-PLAN.md
- [x] 05-03-readme-rewrite-PLAN.md
- [x] 05-04-release-uat-and-milestone-rearchive-PLAN.md

</details>

### 🚧 v2.1.0 Release Pipeline (In Progress)

**Milestone Goal:** Decouple extension and host release tracks with automated publishing via changesets, so every version bump triggers the right publish workflow without manual steps.

- [ ] **Phase 6: Changesets Monorepo Scaffold** - Configure changesets with two private workspace packages, migrate version authority to per-package package.json files
- [ ] **Phase 7: Extension Publishing Pipeline** - Auto-publish extension to Chrome Web Store and Edge Add-ons on extension version bump
- [ ] **Phase 8: Host Release Pipeline** - Auto-create GitHub Release with installer assets on host version bump
- [ ] **Phase 9: Pipeline Integration and Legacy Retirement** - Wire orchestrating release-pipeline.yml, validate end-to-end, retire legacy release.yml

## Phase Details

### Phase 6: Changesets Monorepo Scaffold
**Goal**: Version authority lives in per-package package.json files, changesets is configured with two independent tracks, and a Version Packages PR is auto-created when changesets exist on main
**Depends on**: Nothing (first phase of v2.1.0)
**Requirements**: CS-01, CS-02, CS-03, CS-04, CS-05, CS-06, VER-01, VER-02, VER-03, VER-04
**Success Criteria** (what must be TRUE):
  1. Adding a changeset file to `src/extension` and pushing to main triggers a "Version Packages" PR that bumps only `src/extension/package.json` and generates a git tag `go-mapi-extension@X.Y.Z`
  2. Adding a changeset file to `src/native-host` and pushing to main triggers a "Version Packages" PR that bumps only `src/native-host/package.json` and generates a git tag `go-mapi-host@X.Y.Z`
  3. The Go host binary reports the version string from `src/native-host/package.json` (verified via `--version` flag or READY message)
  4. The Vite extension build embeds the version from `src/extension/package.json` (verified in built manifest.json)
  5. The Inno Setup installer embeds the version from `src/native-host/package.json` (verified in installer file properties)
**Plans**: 3 plans

Plans:
- [ ] 06-01-PLAN.md — Install changesets, create native-host stub, configure workspaces
- [ ] 06-02-PLAN.md — Migrate version sources in build scripts and Vite plugin
- [ ] 06-03-PLAN.md — Create Version Packages CI workflow + CHANGESET_TOKEN setup

### Phase 7: Extension Publishing Pipeline
**Goal**: Merging a Version Packages PR that bumps the extension version automatically publishes the updated extension ZIP to Chrome Web Store and Edge Add-ons without manual steps
**Depends on**: Phase 6
**Requirements**: PUB-01, PUB-02, PUB-03, PUB-04
**Success Criteria** (what must be TRUE):
  1. An extension version bump triggers `publish-extension.yml` which builds the extension ZIP and submits it to Chrome Web Store; the submission is accepted by the CWS API (not necessarily approved by reviewers, which is async)
  2. The same workflow also submits to Edge Add-ons via the v1.1 API; the upload completes without a 4xx/5xx error
  3. All four CWS credentials and all three Edge credentials are stored as repo secrets and the workflow fails loudly if any secret is missing
  4. A host-only changeset does not trigger `publish-extension.yml`
**Plans**: TBD

### Phase 8: Host Release Pipeline
**Goal**: Merging a Version Packages PR that bumps the host version automatically creates a GitHub Release with the installer binary and SHA-256 sidecar at the stable download URL
**Depends on**: Phase 6
**Requirements**: REL-01, REL-02, REL-03
**Success Criteria** (what must be TRUE):
  1. A host version bump dispatches `installer-release.yml` via `workflow_dispatch` with the correct version input; the workflow builds and signs the installer
  2. A GitHub Release is created with `go-mapi-setup.exe` and `go-mapi-setup.exe.sha256` as release assets
  3. `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` returns 200 after the release is published
  4. An extension-only changeset does not trigger `installer-release.yml`
**Plans**: TBD

### Phase 9: Pipeline Integration and Legacy Retirement
**Goal**: A single orchestrating workflow correctly routes extension-only, host-only, and combined changesets to their respective publish jobs, and the legacy release.yml is retired after one validated real release
**Depends on**: Phases 7, 8
**Requirements**: PIPE-01, PIPE-02, PIPE-03
**Success Criteria** (what must be TRUE):
  1. An extension-only changeset fires only `publish-extension.yml`; a host-only changeset fires only `installer-release.yml`; a combined changeset fires both, in sequence
  2. `release-pipeline.yml` is the sole trigger for both downstream publish workflows — no manual tag pushes or workflow_dispatch calls needed after a Version Packages PR merges
  3. `release.yml` is deleted from `.github/workflows/` and the deletion is verified against CI history showing at least one successful end-to-end release via the new pipeline
**Plans**: TBD

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Foundation & SignPath Application | v2.0.0 | 8/8 | Complete | 2026-04-10 |
| 2. Extension Install UX | v2.0.0 | 4/4 | Complete | 2026-04-10 |
| 3. Inno Setup Installer + Signing + Distribution | v2.0.0 | 4/4 | Complete | 2026-04-10 |
| 4. Test-Suite Completeness + E2E | v2.0.0 | 4/4 | Complete | 2026-04-10 |
| 5. Release Cut | v2.0.0 | 4/4 | Complete | 2026-04-12 |
| 6. Changesets Monorepo Scaffold | v2.1.0 | 0/3 | In progress | - |
| 7. Extension Publishing Pipeline | v2.1.0 | 0/? | Not started | - |
| 8. Host Release Pipeline | v2.1.0 | 0/? | Not started | - |
| 9. Pipeline Integration and Legacy Retirement | v2.1.0 | 0/? | Not started | - |

## Coverage

**v2.1.0 requirements:** 20 total
- Mapped to phases: 20
- Unmapped: 0

| Requirement | Phase |
|-------------|-------|
| CS-01 | Phase 6 |
| CS-02 | Phase 6 |
| CS-03 | Phase 6 |
| CS-04 | Phase 6 |
| CS-05 | Phase 6 |
| CS-06 | Phase 6 |
| VER-01 | Phase 6 |
| VER-02 | Phase 6 |
| VER-03 | Phase 6 |
| VER-04 | Phase 6 |
| PUB-01 | Phase 7 |
| PUB-02 | Phase 7 |
| PUB-03 | Phase 7 |
| PUB-04 | Phase 7 |
| REL-01 | Phase 8 |
| REL-02 | Phase 8 |
| REL-03 | Phase 8 |
| PIPE-01 | Phase 9 |
| PIPE-02 | Phase 9 |
| PIPE-03 | Phase 9 |

---
*Roadmap updated: 2026-04-12 — Phase 6 plans created (3 plans in 2 waves)*
