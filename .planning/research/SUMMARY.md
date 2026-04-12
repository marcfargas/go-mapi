# Project Research Summary

**Project:** go-mapi v2.1.0 Release Pipeline
**Domain:** Automated release pipeline — changesets monorepo versioning, dual web store publishing (Chrome + Edge), GitHub Releases
**Researched:** 2026-04-12
**Confidence:** HIGH (changesets patterns, Chrome Web Store API, critical pitfalls); MEDIUM (Edge Add-ons API operational details, changesets private-package GitHub Release edge cases)

## Executive Summary

go-mapi v2.1.0 is an infrastructure milestone that automates what Marc currently does manually: bumping versions, packaging extension ZIPs, publishing to Chrome Web Store and Edge Add-ons, and creating GitHub Releases with the installer binary. The core challenge is that go-mapi has two independently-releasable components (the browser extension and the Go/C++ host) that currently share a single version and a single release workflow. The recommended approach is changesets (`@changesets/cli@2.30.0`) configured with two private workspace packages, giving each component its own version track, CHANGELOG, and git tag, while keeping all non-npm artifacts (Go binary, DLL, installer) out of any npm registry.

The stack additions are minimal: changesets CLI added to root devDependencies, `chrome-webstore-upload-cli` run via `npx` in CI only, and the `birchill/edge-addon-upload` GitHub Action for Edge publishing. No new frameworks or languages. The critical architectural change is migrating version authority away from root `package.json` to per-package `package.json` files (`src/extension/package.json` already exists; `src/native-host/package.json` must be created), and converting existing tag-triggered workflows to `workflow_dispatch`-triggered workflows invoked by the new release pipeline.

The dominant risks are operational rather than technical. Two must be addressed before any pipeline work: (1) `GITHUB_TOKEN` cannot trigger downstream CI workflows — a Fine-Grained PAT must be configured from day one; (2) Edge Add-ons Publish API v1 was deprecated January 10, 2025, meaning any pre-2025 tooling or credential format fails silently. Secondary risks include 72-day Edge API key rotation and Chrome Web Store review delays causing protocol version skew.

## Key Findings

### Recommended Stack

The existing stack requires no changes. v2.1.0 adds exactly three new tools.

**Core technologies:**
- `@changesets/cli@2.30.0`: Monorepo version management with explicit changeset files, "Version Packages" PR automation, independent version tracks per package. `privatePackages: { version: true, tag: true }` enables tagging without npm publishing.
- `chrome-webstore-upload-cli@3.5.0` (via `npx`): Chrome Web Store publishing CLI. 4 secrets: `CWS_EXTENSION_ID`, `CWS_CLIENT_ID`, `CWS_CLIENT_SECRET`, `CWS_REFRESH_TOKEN`.
- `birchill/edge-addon-upload@v1.1.0` (GitHub Action): Edge Add-ons REST API v1.1 upload/poll/publish. 3 secrets: `EDGE_API_KEY`, `EDGE_CLIENT_ID`, `EDGE_PRODUCT_ID`. API key expires every 72 days.

**Supporting:**
- `changesets/action@v1.7.0`: Creates Version Packages PR and runs publish scripts on merge. Needs a Fine-Grained PAT (not GITHUB_TOKEN).
- `softprops/action-gh-release@v2`: Already in use for GitHub Releases. Reused for host releases with changed trigger.

### Expected Features

**Must have (table stakes):**
- Changesets monorepo with two private workspace packages and separate version tracks
- Version Packages PR auto-created on push to `main` when changesets exist
- CHANGELOG auto-generated per package from changeset summaries
- Git tags per package: `go-mapi-extension@X.Y.Z` and `go-mapi-host@X.Y.Z`
- Chrome Web Store auto-publish on extension version bump
- Edge Add-ons auto-publish (same ZIP, second destination)
- GitHub Release for host bumps with installer `.exe` and SHA-256 sidecar
- Stable `releases/latest/download/go-mapi-setup.exe` URL

**Should have:**
- Decoupled CI jobs — extension and host publish as separate jobs gated by `publishedPackages` output

**Defer:**
- Automated Edge API key rotation reminders
- Host self-update detection
- Changesets bot PR comments (overkill for solo maintainer)

**Anti-features:**
- Single version for both packages — prevents independent cadence
- Auto-publish on every push to `develop` — CWS rate limits
- npm registry publishing — both must be `private: true`

### Architecture Approach

This is a migration of version authority and workflow triggers, not a redesign. All existing build logic (MinGW/CMake, Go ldflags, Vite, InnoSetup, SignPath) is unchanged; only the source of the version string and workflow dispatch mechanism changes.

**Major components (new or modified):**
1. `.changeset/config.json` — must include `privatePackages: { version: true, tag: true }`
2. `src/native-host/package.json` (new stub) — gives changesets a package to track for host
3. `.github/workflows/release-pipeline.yml` (new) — runs `changesets/action` on `main`; dispatches publish workflows
4. `.github/workflows/publish-extension.yml` (new) — builds ZIP, publishes to CWS and Edge
5. `installer-release.yml` (modified) — trigger changes from `push: tags: v*` to `workflow_dispatch`
6. `release.yml` (retire after validation)

**Version source migration:**

| Component | Before | After |
|-----------|--------|-------|
| Go host binary | root `package.json` | `src/native-host/package.json` |
| Extension manifest | root `package.json` | `src/extension/package.json` |
| Installer | root `package.json` | `src/native-host/package.json` |

### Critical Pitfalls

1. **`GITHUB_TOKEN` blocks CI on Version Packages PR** — GitHub prevents its own tokens from triggering downstream workflows. Fix: Fine-Grained PAT with `contents: write` and `pull-requests: write`, stored as `CHANGESET_TOKEN`.
2. **`manifest.json` version drift causes store rejection** — changesets bumps `package.json` but manifest retains old version. Fix: `version` lifecycle script syncs `manifest.json` and stages it.
3. **Go binary reads wrong version after monorepo split** — build scripts still read root `package.json`. Fix: update all build steps to read `src/native-host/package.json`.
4. **Edge API v1 deprecated January 2025** — pre-2025 tooling fails silently. Fix: use `birchill/edge-addon-upload@v1.1.0` with v1.1 API credentials.
5. **Existing `release.yml` + `installer-release.yml` race on tags** — both trigger on `v*` tags. Fix: convert to `workflow_dispatch`, dispatch sequentially from release pipeline.
6. **changesets `privatePackages` defaults don't create tags** — default is `tag: false`. Fix: explicit `tag: true` in config.
7. **Chrome review delay causes protocol skew** — host ships while extension is in review queue. Fix: maintain backward compatibility across at least one minor version.

## Implications for Roadmap

### Phase 1: Changesets Monorepo Scaffold
**Rationale:** Foundation for everything else. Nothing downstream is safe to build until changesets is configured and proven to create tags correctly.
**Delivers:** CHANGESET_TOKEN PAT configured; `.changeset/config.json`; `src/native-host/package.json` stub; root `workspaces` updated; version source migrated in all build scripts; Version Packages PR working with CI checks.
**Avoids:** Pitfalls 1 (PAT), 3 (wrong version source), 6 (missing tags).

### Phase 2: Extension Publishing Pipeline
**Rationale:** Most frequent release operation. CWS OAuth approval has external lead time — start immediately after Phase 1.
**Delivers:** `manifest.json` version sync script; `publish-extension.yml` workflow; Chrome Web Store auto-publish; Edge Add-ons auto-publish.
**Avoids:** Pitfalls 2 (manifest drift), 4 (Edge API v1 deprecated), 7 (protocol skew awareness).

### Phase 3: Host Release Pipeline
**Rationale:** Rare but complex. Isolating allows extension pipeline to ship first.
**Delivers:** `installer-release.yml` converted to `workflow_dispatch`; release pipeline dispatches on host version bump; GitHub Release with `.exe` and `.sha256` assets; stable download URL confirmed.
**Avoids:** Pitfall 5 (workflow race).

### Phase 4: Pipeline Integration and Legacy Retirement
**Rationale:** Only retire `release.yml` after at least one successful real release.
**Delivers:** `release-pipeline.yml` fully wired; `release.yml` retired; decoupled CI jobs validated end-to-end.

### Phase Ordering Rationale

- Phase 1 is a hard dependency — tags and version sources are the shared dependency surface
- Phase 2 before Phase 3 because extension releases are more frequent and CWS OAuth has lead time
- Phase 4 last because retiring `release.yml` before the replacement is proven creates a release gap

### Research Flags

Needs deeper research during planning:
- **Phase 2:** Edge Add-ons credential setup (partner-portal-gated), CWS OAuth client type ("Desktop App" vs "Chrome Extension")
- **Phase 3:** changesets GitHub Release creation for private packages (documented edge cases, `workflow_dispatch` workaround safer)

Standard patterns (skip research-phase):
- **Phase 1:** changesets scaffold is well-documented
- **Phase 4:** pure workflow configuration

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | changesets 2.30.0, chrome-webstore-upload-cli 3.5.0, birchill/edge-addon-upload 1.1.0 verified |
| Features | MEDIUM-HIGH | P1 features derived from current manual process. Edge 72-day rotation confirmed. |
| Architecture | HIGH | Version source migration and workflow_dispatch pattern verified |
| Pitfalls | HIGH | All critical pitfalls verified against official docs and GitHub issues |

**Overall confidence:** HIGH for Phases 1 and 2 (Chrome). MEDIUM for Phase 2 (Edge) and Phase 3.

### Gaps to Address

- Edge API key rotation operationalization: 72-day expiry needs a plan (calendar reminder vs automated workflow)
- First manual store submissions: both CWS and Edge require initial manual submission before API works
- SignPath credential validity: Phase 3 preserves signing logic but secrets must be valid
- changesets `createGithubReleases` for private packages: needs Phase 3 dry-run validation

## Sources

### Primary (HIGH confidence)
- [changesets/changesets](https://github.com/changesets/changesets) — v2.30.0, config options, `privatePackages`
- [changesets/action](https://github.com/changesets/action) — v1.7.0, `publish` input, `publishedPackages` output
- [changesets/action#70, #99](https://github.com/changesets/action/issues/70) — GITHUB_TOKEN PAT requirement
- [fregante/chrome-webstore-upload-cli](https://github.com/fregante/chrome-webstore-upload-cli) — v3.5.0
- [Microsoft Learn: Edge Add-ons REST API](https://learn.microsoft.com/en-us/microsoft-edge/extensions/update/api/using-addons-api) — v1.1 endpoints
- [Microsoft Edge Blog Jan 2025](https://blogs.windows.com/msedgedev/2025/01/08/) — 72-day API key expiry

### Secondary (MEDIUM confidence)
- [changesets/action#269](https://github.com/changesets/action/issues/269) — GitHub Release for non-npm packages
- [Chrome Web Store API docs](https://developer.chrome.com/docs/webstore/using-api) — OAuth client type

---
*Research completed: 2026-04-12*
*Ready for roadmap: yes*
