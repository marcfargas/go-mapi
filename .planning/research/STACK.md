# Stack Research — go-mapi v2.1.0 Release Pipeline

**Domain:** Automated release pipeline for a mixed Go/TypeScript/C++ Windows app with a browser extension
**Researched:** 2026-04-12
**Confidence:** HIGH (changesets, chrome-webstore-upload), MEDIUM (Edge Add-ons API, workflow trigger pattern)

## Scope Note

This document covers **additions only** for the v2.1.0 Release Pipeline milestone. The existing stack
(Go 1.21, C++17/MinGW, TypeScript 5.3, React 18, Vite 5, Vitest 2, Playwright 1.58, Inno Setup 6,
`softprops/action-gh-release@v2`) is already validated and does not need re-evaluation. The existing
`release.yml` and `installer-release.yml` workflows remain in place; new workflows augment them.

---

## Part A — Monorepo Versioning: Changesets

### A.1 Core Tool

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| **@changesets/cli** | 2.30.0 (March 2026) | Manages version bumps, CHANGELOG.md generation, and git tags per package | Purpose-built for monorepos with independent version tracks; creates a "Version Packages" PR that bumps versions and generates changelogs atomically; private-package support means non-npm artifacts (Go host, DLL) can be versioned and tagged without publishing to any registry |
| **@changesets/action** | v1.7.0 (February 2026) | GitHub Action that creates the Version Packages PR and optionally runs a publish script on merge | Eliminates manual version PRs; the `publish` input accepts any shell command so it can drive non-npm release steps (zip, attach to GitHub Release, call store APIs) |

**Why changesets over semantic-release or standard-version:**
- semantic-release is commit-message-only; changesets uses explicit changeset files, making each change deliberate and reviewable before it lands
- standard-version is deprecated (last release 2022)
- changesets was designed for the monorepo + independent-version-tracks use case that this project needs (extension releases frequently; host/installer rarely)

### A.2 Package Configuration for Private Packages

Changesets supports two package types in this repo:

**Extension package** (`src/extension/package.json`) — already `private: true` (not published to npm). Configure with:
```json
{
  "name": "go-mapi-extension",
  "private": true,
  "version": "2.0.0"
}
```

**Host package** (add `package.json` at `src/native-host/`) — wrapper for versioning the Go binary:
```json
{
  "name": "go-mapi-host",
  "private": true,
  "version": "2.0.0"
}
```

**`.changeset/config.json`** — key settings:
```json
{
  "$schema": "https://unpkg.com/@changesets/config/schema.json",
  "changelog": "@changesets/cli/changelog",
  "commit": false,
  "fixed": [],
  "linked": [],
  "access": "restricted",
  "baseBranch": "main",
  "updateInternalDependencies": "patch",
  "privatePackages": {
    "version": true,
    "tag": true
  },
  "ignore": []
}
```

Setting `privatePackages.tag: true` makes changesets create git tags like `go-mapi-extension@2.1.0` and
`go-mapi-host@2.1.0` when the Version Packages PR is merged. Those tags are what downstream workflows
(store publish, GitHub Release) listen on.

**Critical:** Packages are NOT in the root `workspaces` field for changesets tracking purposes — changesets
discovers them from the `workspaces` field in the root `package.json`. The root already has
`"workspaces": ["src/extension"]`. Add `"src/native-host"` to that array so changesets can find both.

### A.3 Workflow Trigger Pattern

Changesets-created tags do **not** automatically trigger other workflows in the same run — GitHub Actions
prevents recursive triggering. The recommended pattern is:

1. `changesets/action` runs on push to `main`, creates the Version Packages PR
2. On merge of that PR, `changesets/action` runs again with a `publish` script
3. The `publish` script creates git tags explicitly (changesets does this automatically when `privatePackages.tag: true`)
4. Separate workflows listen on `on: push: tags: ['go-mapi-extension@*']` and `on: push: tags: ['go-mapi-host@*']`

The separate tag-pattern listeners are the correct solution for this repo because the extension and host have
independent release cadences. Tag push triggers work because the tags are created in a separate step, not
within the same GitHub Actions run that would trigger recursion.

---

## Part B — Chrome Web Store Publishing

### B.1 Tool

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| **chrome-webstore-upload-cli** | 3.5.0 (October 2025) | CLI for uploading and publishing Chrome extensions via the Chrome Web Store API | Maintained by fregante (prolific browser-extension tooling author), no GitHub Action dependency (just `npx`), supports upload-only or upload+publish in one command, accepts zip or directory |

**Installation (in CI only — not a local dev dependency):**
```bash
npx chrome-webstore-upload-cli upload --source extension.zip --extension-id $EXT_ID
npx chrome-webstore-upload-cli publish --extension-id $EXT_ID
```

Or combine with `npx chrome-webstore-upload-cli` (no subcommand = upload + publish).

**Credentials required (GitHub Actions secrets):**
| Secret | What It Is |
|--------|-----------|
| `CHROME_EXTENSION_ID` | Extension ID from Chrome Web Store dashboard |
| `CHROME_CLIENT_ID` | OAuth2 client ID from Google Cloud Console |
| `CHROME_CLIENT_SECRET` | OAuth2 client secret |
| `CHROME_REFRESH_TOKEN` | Long-lived refresh token (does not expire unless unused for 6 months) |

**Credential setup process** (one-time, manual): Follow the `chrome-webstore-upload-keys` guide to create
a Google Cloud project with the Chrome Web Store API enabled, create OAuth credentials, and generate a
refresh token. This is a developer setup step, not something that can be automated.

**Do NOT use as a dev dependency** — run via `npx` in CI only. The credentials are store-specific and not
needed locally. This keeps the root `package.json` clean.

---

## Part C — Edge Add-ons Publishing

### C.1 Tool

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| **birchill/edge-addon-upload** (GitHub Action) | v1.1.0 | Uploads a zip to Edge Add-ons Partner Center via the v1.1 REST API | Wraps the multi-step upload → poll → publish REST flow; official API is stable (v1.1 as of Sep 2024, v1 EOL Dec 2024) |

**Usage in workflow:**
```yaml
- uses: birchill/edge-addon-upload@v1.1.0
  with:
    addon_file: extension.zip
    api_key: ${{ secrets.EDGE_API_KEY }}
    client_id: ${{ secrets.EDGE_CLIENT_ID }}
    product_id: ${{ secrets.EDGE_PRODUCT_ID }}
```

**Credentials required (GitHub Actions secrets):**
| Secret | What It Is |
|--------|-----------|
| `EDGE_API_KEY` | API key from Partner Center → Microsoft Edge → Publish API (v1.1) |
| `EDGE_CLIENT_ID` | Client ID from same Publish API page |
| `EDGE_PRODUCT_ID` | 128-bit GUID product ID from Partner Center extension overview |

**API version:** Use v1.1 (API-key-based). v1 (access-token-based) support ends December 31, 2024.

**Important constraint:** The first submission must be done manually via Partner Center UI. The REST API
only updates existing published extensions — it cannot create a new product listing.

**Alternative:** If `birchill/edge-addon-upload` is insufficiently maintained, the Edge Add-ons REST API
is simple enough (4 endpoints: upload, check upload, publish, check publish) to script directly in bash
using `curl` within a workflow step. Microsoft provides a PowerShell example in their official docs.

---

## Part D — GitHub Releases (existing, minor additions)

The existing `softprops/action-gh-release@v2` (v2.6.1 as of early 2026) already handles GitHub Releases
in `release.yml` and `installer-release.yml`. For the new pipeline:

- Extension releases: create a lightweight GitHub Release tagged `go-mapi-extension@X.Y.Z` with the
  extension zip as an asset and the changeset-generated CHANGELOG entry as the body
- Host releases: existing `installer-release.yml` continues to handle this; it will be adapted to trigger
  on `go-mapi-host@*` tags instead of `v*` tags

No new GitHub Release tooling is needed. `softprops/action-gh-release@v2` handles both.

---

## Installation

```bash
# Changesets CLI (add to root devDependencies)
npm install -D @changesets/cli

# Initialize changesets (run once)
npx changeset init
```

No other packages are added to `package.json`. Edge and Chrome publishing tools run via `npx`/GitHub
Actions in CI only — no local dev dependency needed.

**Root `package.json` changes:**
- Add `"src/native-host"` to `workspaces` array
- Add `"@changesets/cli"` to `devDependencies`
- Add scripts: `"changeset": "changeset"`, `"version-packages": "changeset version"`, `"release": "changeset tag"`

---

## Alternatives Considered

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| changesets | semantic-release | semantic-release derives versions from commit message conventions (breaking, feat, fix); changesets uses explicit per-change files which are more deliberate and reviewable; also, semantic-release's monorepo support via `@semantic-release/exec` is more complex to configure for two independent tracks |
| changesets | Release Please (Google) | Release Please is excellent but targets Google's own mono-repo convention; changesets has better npm workspace integration and the `privatePackages.tag` feature fits the non-npm artifact case |
| chrome-webstore-upload-cli | mnao305/chrome-extension-upload (Action) | Both are valid; `chrome-webstore-upload-cli` is a lower-level, dependency-free CLI that runs via `npx` — no pinned Action version to keep updated |
| birchill/edge-addon-upload | Custom curl script | The Action handles the async polling loop (upload → wait → publish → wait) correctly; writing that in bash is error-prone and verbose |
| Tag-based workflow triggers | `workflow_dispatch` triggers | Tag triggers are self-documenting (the tag IS the version) and work correctly for independent version tracks; `workflow_dispatch` requires manual intervention |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `standard-version` | Deprecated since 2022, no monorepo support | `@changesets/cli` |
| `release-it` | Feature-rich but no native monorepo/independent-track support without plugins; less convention around the "Version PR" pattern | `@changesets/cli` |
| `semantic-release` monorepo plugins | Configuration complexity for two independent tracks outweighs benefits for a solo project | `@changesets/cli` |
| Chrome Web Store API directly (raw HTTP) | Requires OAuth flow management; `chrome-webstore-upload-cli` already handles this | `chrome-webstore-upload-cli` |
| Edge Add-ons API v1 (access-token) | EOL December 31, 2024 | Edge Add-ons API v1.1 (API-key-based) |
| Root-level `package.json` version as the single source of truth | Prevents independent version tracks for extension vs host | Per-package `package.json` versions managed by changesets |

---

## Version Compatibility

| Package | Compatible With | Notes |
|---------|----------------|-------|
| `@changesets/cli@2.30.0` | Node 18+, npm workspaces | Requires packages to have `name`, `version`, `private` fields in their `package.json` |
| `@changesets/action@v1.7.0` | GitHub Actions, any branch | Uses `GITHUB_TOKEN` for PR creation; needs `contents: write` and `pull-requests: write` permissions |
| `chrome-webstore-upload-cli@3.5.0` | Node 18+, npx | Refresh token expires if unused for 6 months — document in runbook |
| `birchill/edge-addon-upload@v1.1.0` | GitHub Actions | Requires first submission via Partner Center UI |
| `softprops/action-gh-release@v2` (v2.6.1) | GitHub Actions | Already in use; tag pattern changes from `v*` to `go-mapi-extension@*` / `go-mapi-host@*` |

---

## Integration Points

### What changes in existing files

| File | Change Needed |
|------|--------------|
| Root `package.json` | Add `src/native-host` to `workspaces`; add `@changesets/cli` to `devDependencies`; add `changeset`, `version-packages`, `release` scripts |
| `src/native-host/package.json` | Create new file: `{ "name": "go-mapi-host", "private": true, "version": "2.0.0" }` |
| `.github/workflows/release.yml` | Change tag trigger from `v*` to `go-mapi-host@*` (or remove if installer-release.yml takes over) |
| `.github/workflows/installer-release.yml` | Change tag trigger from `v*` to `go-mapi-host@*` |

### New files needed

| File | Purpose |
|------|---------|
| `.changeset/config.json` | Changesets configuration (see A.2 above) |
| `.github/workflows/changesets.yml` | Runs `changesets/action` on push to `main`; creates Version Packages PR; runs publish script on merge |
| `.github/workflows/publish-extension.yml` | Triggered by `go-mapi-extension@*` tags; builds extension zip, publishes to Chrome Web Store + Edge Add-ons, creates GitHub Release |

---

## Sources

- [changesets/changesets GitHub](https://github.com/changesets/changesets) — version 2.30.0 confirmed, config options, private packages behavior
- [changesets/action GitHub](https://github.com/changesets/action) — v1.7.0 confirmed, `publish` input flexibility
- [changesets versioning apps docs](https://github.com/changesets/changesets/blob/main/docs/versioning-apps.md) — `privatePackages.tag: true` pattern, minimal `package.json` requirements
- [changesets config file options](https://github.com/changesets/changesets/blob/main/docs/config-file-options.md) — `privatePackages`, `baseBranch`, `linked`, `fixed` fields
- [changesets issue #1111](https://github.com/changesets/changesets/issues/1111) — GitHub release without npm publish pattern, workflow trigger constraints
- [fregante/chrome-webstore-upload-cli GitHub](https://github.com/fregante/chrome-webstore-upload-cli) — v3.5.0 confirmed (Oct 2025), credential requirements
- [Microsoft Edge Add-ons REST API docs](https://learn.microsoft.com/en-us/microsoft-edge/extensions/update/api/using-addons-api) — v1.1 endpoints, credential types, upload/publish flow (updated March 2026)
- [birchill/edge-addon-upload GitHub Marketplace](https://github.com/marketplace/actions/upload-to-edge-add-ons) — v1.1.0 confirmed, input parameters
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release) — v2.6.1 confirmed, body_path and asset attachment

---

*Stack research for: go-mapi v2.1.0 Release Pipeline (changesets + store publishing)*
*Researched: 2026-04-12*
