# Architecture Research

**Domain:** Release pipeline integration — changesets monorepo dual-package, Chrome/Edge Web Store publishing, GitHub Releases for host installer
**Researched:** 2026-04-12
**Confidence:** HIGH for changesets config patterns and Chrome Web Store API (verified against official docs). MEDIUM for Edge Add-ons API (official API exists but credential setup is partner-portal-gated). MEDIUM for changesets private-package tag behavior (documented but has known edge-case bugs with GitHub Release creation).

> **Scope reminder.** This document covers ONLY what v2.1.0 adds to the release pipeline. It does NOT redesign the bridge components. Existing architecture is documented in `.planning/codebase/ARCHITECTURE.md`. The existing build workflows are the integration surface.

---

## 1. Current State (What Exists)

### Version Authority — Single Source, Single Track

Everything currently derives version from root `package.json`:

```
root/package.json  "version": "2.0.0"
       │
       ├──▶ build:native-host  →  -ldflags "-X main.Version=2.0.0"  →  go-mapi-host.exe
       ├──▶ build:extension    →  Vite reads package.json → manifest.json baked at build
       └──▶ build:installer    →  iscc /DGOMAPIVersion=2.0.0         →  go-mapi-setup.exe
```

`src/extension/package.json` exists as a workspace member but its `"version"` field is not currently the authority for the extension manifest — Vite/build scripts read the root.

### Existing CI Workflows

| Workflow | Trigger | What It Does |
|----------|---------|-------------|
| `build.yml` | push to main/develop, PR | Builds all three components, runs tests, uploads artifacts |
| `release.yml` | push `v*` tag | Rebuilds everything, creates GitHub Release with DLL + host + extension ZIP + install script |
| `installer-release.yml` | push `v*` tag | Builds installer, optionally signs via SignPath, publishes `go-mapi-setup.exe` to GitHub Release |
| `go-race-nightly.yml` | scheduled | Go race detector tests |
| `e2e.yml` | PR/push | Playwright E2E tests |
| `installer-smoke.yml` | PR/push | Installer smoke tests |

**Problem:** Both `release.yml` and `installer-release.yml` trigger on any `v*` tag. They treat extension and host as a single release unit. There is no way to publish only the extension without a full host/installer rebuild.

### Current Workspace Structure

```
go-mapi/                        ← root (private, version "2.0.0")
  package.json                  ← version authority for everything
  .github/workflows/            ← CI/CD
  src/
    extension/                  ← npm workspace "go-mapi-extension"
      package.json              ← version "2.0.0" (not the authority today)
    native-host/                ← Go module (not an npm package)
    interceptor/                ← C++ (not an npm package)
    installer/                  ← InnoSetup script
```

---

## 2. Target State (What v2.1.0 Adds)

### Decoupled Version Tracks

```
.changeset/config.json
       │
       ├── package: "go-mapi-extension"   →  src/extension/package.json  →  extension version
       └── package: "go-mapi-host"        →  host-package.json (new)      →  host/installer version
```

The Go host has no `package.json` today. A minimal `host-package.json` (or `src/native-host/package.json`) with `"private": true` and `"name": "go-mapi-host"` gives changesets something to update. This is the canonical changesets pattern for non-npm packages.

### New Release Data Flow

```
Developer writes changeset
        │
        ▼
.changeset/*.md  committed to develop/main
        │
        ▼  (changesets/action on push to main)
"Version Packages" PR created/updated
  - bumps src/extension/package.json
  - bumps host-package.json
  - updates CHANGELOG.md files
        │
        ▼  (PR merged)
changesets/action publish hook fires
        │
        ├──▶ extension version bump detected?
        │         └──▶ trigger: build extension + publish to CWS + publish to Edge Add-ons
        │
        └──▶ host version bump detected?
                  └──▶ trigger: build DLL + host + installer + sign + publish GitHub Release
```

---

## 3. Component Boundaries (New vs Modified)

### New Components

| Component | Location | What It Is |
|-----------|----------|------------|
| Changesets config | `.changeset/config.json` | Controls which packages are versioned, tag creation, ignore list |
| Host package stub | `src/native-host/package.json` | `{"name":"go-mapi-host","version":"2.0.0","private":true}` — gives changesets a package.json to bump |
| Extension publish script | `scripts/publish-extension.sh` (or inline in workflow) | Zips `src/extension/dist/`, calls chrome-webstore-upload or CWS API |
| Changesets CI workflow | `.github/workflows/release-pipeline.yml` | Runs `changesets/action`, dispatches publish jobs |
| CWS publish workflow | `.github/workflows/publish-extension.yml` | Builds + publishes extension to Chrome Web Store and Edge Add-ons |
| Host release workflow | `.github/workflows/publish-host.yml` | Builds + signs + publishes installer to GitHub Releases |

### Modified Components

| Component | Change |
|-----------|--------|
| `src/extension/package.json` | Becomes the version authority for the extension (was already a workspace package but version was ignored) |
| `build.yml` | Add `workflow_call` trigger from release pipeline; version now read from `src/extension/package.json` for extension builds |
| `installer-release.yml` | Converted from tag-triggered to `workflow_call` triggered by publish-host.yml; version comes from host-package.json, not a manually pushed tag |
| `release.yml` | Retired or scoped down — changesets handles tagging now |
| Root `package.json` | Remove as version authority for DLL/host/extension. Root version becomes "pipeline metadata" or is dropped in favor of per-package versions. Scripts that read it for version injection must be updated. |

### Unchanged Components

- `build.yml` build logic (just the trigger changes)
- `installer-release.yml` build + signing logic (just the trigger and version source change)
- `src/interceptor/build.ps1` — DLL build is driven by host version
- InnoSetup `.iss` script — still receives version via `/DGOMAPIVersion=` flag
- Go host ldflags version injection — still works, source changes to host-package.json

---

## 4. Changesets Configuration Architecture

### Package Registry

```json
// .changeset/config.json
{
  "$schema": "https://unpkg.com/@changesets/config@3.0.0/schema.json",
  "changelog": "@changesets/cli/changelog",
  "commit": false,
  "fixed": [],
  "linked": [],
  "access": "restricted",
  "baseBranch": "main",
  "updateInternalDependencies": "patch",
  "ignore": [],
  "privatePackages": {
    "version": true,
    "tag": true
  }
}
```

`privatePackages.tag: true` is required because both packages are private. Without it, changesets updates versions but never creates git tags — and git tags are the trigger for publish workflows.

### Package Setup

```
# Extension package — already exists, needs version authority confirmed
src/extension/package.json
  "name": "go-mapi-extension"
  "private": true
  "version": "2.0.0"

# Host package stub — NEW, placed at root of native-host
src/native-host/package.json
  "name": "go-mapi-host"
  "private": true
  "version": "2.0.0"
```

The root `package.json` workspace array must include `src/native-host` so changesets sees it:

```json
// root package.json
"workspaces": [
  "src/extension",
  "src/native-host"
]
```

### Version Bump → Tag → Publish Flow

```
changeset version runs
  → src/extension/package.json bumped (e.g., 2.0.0 → 2.1.0)
  → src/native-host/package.json bumped (e.g., 2.0.0 → 2.1.0)
  → CHANGELOG files updated

Version Packages PR merged → changesets/action publish hook
  → changeset publish runs
  → for each package with version bump:
       creates git tag: go-mapi-extension@2.1.0
       creates git tag: go-mapi-host@2.1.0
  → publish script runs per package
       go-mapi-extension: build + upload to CWS/Edge
       go-mapi-host: trigger installer build workflow
```

**Critical limitation:** `changeset publish` only creates GitHub Releases for packages it successfully "publishes." For private packages with no npm publish step, GitHub Releases are not auto-created. The workaround: the publish script for `go-mapi-host` triggers `installer-release.yml` via `workflow_dispatch`, which creates the GitHub Release itself.

---

## 5. Publish Script Architecture

### Extension Publish Path

```
publish script (go-mapi-extension)
  1. npm run -w go-mapi-extension build        (Vite build → dist/)
  2. Zip dist/ → go-mapi-extension-X.Y.Z.zip
  3. chrome-webstore-upload upload              (Chrome Web Store API)
  4. wdzeng/edge-addon or equivalent           (Edge Add-ons API v1.1)
  5. Exit 0 → changeset publish marks package as published, creates tag
```

**Chrome Web Store credentials (repository secrets):**
- `CWS_EXTENSION_ID` — 32-character extension ID from Chrome Web Store developer dashboard
- `CWS_CLIENT_ID` — OAuth2 client ID (from GCP project, scope: `chromewebstore`)
- `CWS_CLIENT_SECRET` — OAuth2 client secret
- `CWS_REFRESH_TOKEN` — Long-lived refresh token (obtained once via OAuth flow)

**Edge Add-ons credentials (repository secrets):**
- `EDGE_PRODUCT_ID` — Product ID from Edge Partner Center
- `EDGE_CLIENT_ID` — API client ID from Edge Partner Center
- `EDGE_API_KEY` — API key from Edge Partner Center (Edge Add-ons API v1.1)

### Host Publish Path

```
publish script (go-mapi-host)
  1. Read version from src/native-host/package.json
  2. gh workflow run installer-release.yml --field version=X.Y.Z
  3. Exit 0 → changeset publish marks package as published, creates tag
  (installer-release.yml handles the actual build + sign + GitHub Release)
```

Alternatively: the `changesets/action` `publish` output `publishedPackages` can be read in subsequent workflow steps to conditionally trigger the installer workflow, keeping the publish script simpler.

---

## 6. Version Source Changes

### Problem: Root package.json was the single version authority

Three places inject version into build artifacts:

1. **Go host binary**: `go build -ldflags "-X main.Version=<ver>"` — currently reads root `package.json`
2. **Extension manifest**: Vite build reads root `package.json` via a build plugin/script
3. **Installer**: `iscc /DGOMAPIVersion=<ver>` — currently passed explicitly in workflows

### After v2.1.0

Each component reads from its own package source:

| Component | Version Source |
|-----------|---------------|
| go-mapi-host binary | `src/native-host/package.json` |
| Extension manifest (at build) | `src/extension/package.json` |
| Installer | `src/native-host/package.json` (same as host) |

The `build:native-host` npm script must be updated to read from `src/native-host/package.json` instead of root. The Vite extension build already runs in the `src/extension` workspace context so `package.json` is local.

### Extension Manifest Version Format Constraint

Chrome Web Store accepts version in format `X.Y.Z` or `X.Y.Z.W` (1–4 dot-separated integers, 0–65535 each). **Semver prerelease labels are not supported** — `2.1.0-alpha.1` cannot be used in `manifest.json`. The Vite build plugin must strip any prerelease suffix when writing the manifest version field. This is a non-obvious constraint that affects how changesets prerelease mode works for the extension package.

---

## 7. CI Workflow Architecture (Target)

### New Workflow: `release-pipeline.yml`

```yaml
# Triggers on push to main (after Version Packages PR merge)
# Runs changesets/action in publish mode
on:
  push:
    branches: [main]

jobs:
  release:
    runs-on: ubuntu-latest  # changesets itself is platform-agnostic
    outputs:
      published: ${{ steps.changesets.outputs.published }}
      publishedPackages: ${{ steps.changesets.outputs.publishedPackages }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
      - run: npm ci
      - uses: changesets/action@v1
        id: changesets
        with:
          publish: npm run release     # calls changeset publish
          version: npm run version     # calls changeset version
          title: "chore: release packages"
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          # Store publish credentials available to publish scripts:
          CWS_CLIENT_ID: ${{ secrets.CWS_CLIENT_ID }}
          # ... etc
```

### Modified Workflow: `installer-release.yml`

Retain all existing build/sign/release logic. Change trigger from `push: tags: v*` to `workflow_dispatch` with a `version` input. The release pipeline workflow dispatches it after host package version bump is detected.

### Retired Workflow: `release.yml`

`release.yml` currently builds everything on `v*` tag push and creates a GitHub Release. Once changesets controls tagging and the host/extension publish pipelines are separate, `release.yml` is either retired or repurposed as a manual fallback.

---

## 8. Data Flow Diagram

```
Developer adds changeset:
  npx changeset → .changeset/abc123.md → committed to develop

Merge to main:
  push to main triggers release-pipeline.yml

  Case A: changesets exist (first run after Version Packages PR merge)
    changesets/action → creates "Version Packages" PR
    (PR contains: bumped package.json files + CHANGELOG updates)

  Case B: Version Packages PR is merged to main
    changesets/action → runs publish script
    publish script:
      ├── go-mapi-extension version bumped?
      │     └── build extension
      │           ├── upload to Chrome Web Store   (CWS API + secrets)
      │           └── upload to Edge Add-ons       (Edge API v1.1 + secrets)
      │
      └── go-mapi-host version bumped?
            └── trigger installer-release.yml (workflow_dispatch)
                  ├── build DLL (MinGW + CMake, windows-latest)
                  ├── build host binary (Go, windows-latest)
                  ├── sign via SignPath (gated on SIGNPATH_API_TOKEN)
                  ├── build installer (InnoSetup 6)
                  ├── sign installer (gated on SIGNPATH_API_TOKEN)
                  └── create GitHub Release (softprops/action-gh-release@v2)
                        └── attach go-mapi-setup.exe
```

---

## 9. Anti-Patterns to Avoid

### Anti-Pattern 1: Shared Version PR for Extension + Host

**What:** Both packages version-bump together in the same "Version Packages" PR every time.
**Why bad:** Extension iterates frequently; host is lean and stable. Forcing a host version bump (and full Windows build + signing) on every extension change negates the decoupled track goal.
**Do this instead:** Keep packages separate in changesets. Only add a host changeset when host/DLL/installer actually changes.

### Anti-Pattern 2: Using Root package.json Version for Build Injection

**What:** Continuing to read root `package.json` version in build scripts after introducing per-package versions.
**Why bad:** Root version diverges from the package-specific versions changesets manages. Installers and binaries get the wrong version baked in.
**Do this instead:** Each build step reads version from the package it is building: `jq -r '.version' src/native-host/package.json`, not root.

### Anti-Pattern 3: Prerelease Labels in Extension Manifest

**What:** Using changesets pre-release mode and letting `2.1.0-beta.1` flow into `manifest.json`.
**Why bad:** Chrome Web Store rejects the extension package at upload — manifest version must be `X.Y.Z` integers only.
**Do this instead:** Strip prerelease suffix in the Vite build plugin when writing manifest version. Keep the semver label in `package.json` for changesets; write only the numeric prefix to the manifest.

### Anti-Pattern 4: Triggering Publish on Every Push to Main

**What:** The publish script runs and tries to publish on every `push` to main, not just when the Version Packages PR merges.
**Why bad:** Re-uploads the same extension version, potentially hitting rate limits or causing CWS review delays.
**Do this instead:** Use `changesets/action` output `published: true` as a gate. Publish steps only run when changesets confirms new packages were published.

### Anti-Pattern 5: Hardcoded Tag Format Assumptions

**What:** Existing workflows assume tag format `v*` (e.g., `v2.1.0`). Changesets creates package-scoped tags: `go-mapi-extension@2.1.0`.
**Why bad:** `release.yml` and `installer-release.yml` both trigger on `v*` — they will not trigger from changesets-created tags without modification.
**Do this instead:** Switch publish triggers from tag-push to `workflow_dispatch` or `workflow_call` from the release pipeline. Do not rely on git tag format for workflow dispatch.

---

## 10. Integration Points Summary

| Integration | New/Modified | Mechanism | Credentials Needed |
|-------------|-------------|-----------|-------------------|
| Changesets Version PR | New | `changesets/action@v1` + GITHUB_TOKEN | `GITHUB_TOKEN` (write to PR) |
| Chrome Web Store publish | New | `chrome-webstore-upload` CLI or `mnao305/chrome-extension-upload@v6` | `CWS_CLIENT_ID`, `CWS_CLIENT_SECRET`, `CWS_REFRESH_TOKEN`, `CWS_EXTENSION_ID` |
| Edge Add-ons publish | New | `wdzeng/edge-addon` action or Edge API v1.1 directly | `EDGE_PRODUCT_ID`, `EDGE_CLIENT_ID`, `EDGE_API_KEY` |
| GitHub Release (host) | Modified trigger | `installer-release.yml` via `workflow_dispatch` | `GITHUB_TOKEN` (already in place) |
| SignPath signing | Unchanged | `SignPath/github-action-submit-signing-request@v1` | `SIGNPATH_API_TOKEN` etc (already in place) |
| Go host version injection | Modified source | Read from `src/native-host/package.json` instead of root | None |
| Extension manifest version | Modified source | Read from `src/extension/package.json`, strip prerelease suffix | None |

---

## 11. Build Order for v2.1.0 Phase Work

The dependencies between tasks determine sequencing:

1. **Changesets scaffold** — `.changeset/config.json`, host package stub, root workspace update. Nothing else can proceed until changesets knows both packages. No CI changes yet.

2. **Version source migration** — Update `build:native-host` script and Vite build plugin to read from per-package `package.json`. Validate that existing build still produces correct versions. Gate: CI green on develop.

3. **Extension publish pipeline** — Add `publish-extension.yml` workflow. Requires CWS credentials and Edge Add-ons credentials configured as secrets. This is independently testable (manual `workflow_dispatch` with a dev build).

4. **Host publish pipeline** — Convert `installer-release.yml` to `workflow_dispatch`-triggered. Add dispatch call from release pipeline. Validate end-to-end with a manual dispatch. Existing signing logic is unchanged.

5. **Release pipeline workflow** — Wire `changesets/action` into `release-pipeline.yml`. Test with a real changeset cycle on develop→main. This is the integration step that ties 3 and 4 together.

6. **Retire `release.yml`** — Only safe to do after the new pipeline produces a successful end-to-end release. Keep as manual fallback until confirmed.

---

## Sources

- Changesets config options: https://github.com/changesets/changesets/blob/main/docs/config-file-options.md
- Changesets versioning apps (non-npm): https://github.com/changesets/changesets/blob/main/docs/versioning-apps.md
- Changesets GitHub Action: https://github.com/changesets/action
- Chrome Web Store version format (integer-only, no semver prerelease): https://developer.chrome.com/docs/apps/manifest/version
- Chrome Web Store automated publishing: https://github.com/mnao305/chrome-extension-upload
- Edge Add-ons API announcement: https://techcommunity.microsoft.com/discussions/edgeinsiderannouncements/introducing-api-to-automate-publishing-and-updating-microsoft-edge-add-ons/2654592
- Edge Add-ons GitHub Action (`wdzeng/edge-addon`): https://github.com/wdzeng/edge-addon
- Changesets private packages tag discussion: https://github.com/changesets/changesets/discussions/1312
- Changesets GitHub Releases for non-npm packages issue: https://github.com/changesets/action/issues/269

---
*Architecture research for: release pipeline integration (v2.1.0)*
*Researched: 2026-04-12*
