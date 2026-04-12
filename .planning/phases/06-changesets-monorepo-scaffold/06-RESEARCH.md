# Phase 6: Changesets Monorepo Scaffold - Research

**Researched:** 2026-04-12
**Domain:** Changesets CLI, GitHub Actions, version injection (Vite + Go ldflags + PowerShell)
**Confidence:** HIGH (core changesets config verified via official docs; action behavior verified via GitHub issue tracker and official README)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Both packages start at version 2.1.0 (clean start for new milestone)
- **D-02:** Remove the `version` field from root `package.json` entirely
- **D-03:** Build scripts must read version from their respective per-package `package.json`
- **D-04:** Changeset files added on `develop`, detected when develop merges to `main`; `changesets/action@v1.7.0` creates the Version Packages PR on `main`
- **D-05:** Version Packages PR requires manual merge — no auto-merge
- **D-06:** Vite injects version from `src/extension/package.json` into output `manifest.json` at build time; existing `vite.config.ts` is the integration point
- **D-07:** Dev builds use `{version}-dev+{commithash}` format; Vite strips prerelease/build metadata for production
- **D-08:** Clean tag break: `go-mapi-extension@X.Y.Z` and `go-mapi-host@X.Y.Z`; old `v*` tags stay in history
- **D-09:** `installer-release.yml` switches to `workflow_dispatch` in Phase 8 — no interim tag compatibility needed here

### Claude's Discretion

- Exact `.changeset/config.json` structure and options
- How to structure `src/native-host/package.json` stub (minimal fields)
- CI workflow YAML structure for the changesets action
- Whether to use `changesets/action` default commit message format or customize it

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CS-01 | `.changeset/config.json` with `privatePackages: { version: true, tag: true }` | Verified: `privatePackages.tag: true` enables git tags for private packages |
| CS-02 | `src/native-host/package.json` stub as private workspace package | Verified: minimal `package.json` with `"private": true` and `"version": "2.1.0"` is sufficient |
| CS-03 | Root `package.json` `workspaces` includes both packages | Verified: npm workspaces supports multiple entries; currently only has `src/extension` |
| CS-04 | Per-package git tags (`go-mapi-extension@X.Y.Z`, `go-mapi-host@X.Y.Z`) | Verified: changesets default tag format for named packages is `{packageName}@{version}` |
| CS-05 | Fine-Grained PAT (`CHANGESET_TOKEN`) as repo secret | Verified: PAT needs `contents: write` + `pull-requests: write`; GITHUB_TOKEN cannot trigger downstream CI |
| CS-06 | Version Packages PR auto-created by `changesets/action@v1.7.0` on push to `main` | Verified: confirmed action behavior — creates PR when changesets exist, no-ops otherwise |
| VER-01 | Extension build reads version from `src/extension/package.json` | Existing `stampManifestVersion` plugin reads from root — needs to switch to `__dirname`-relative path |
| VER-02 | Go host build reads version from `src/native-host/package.json` via ldflags | Pattern exists; build scripts need to switch source from `package.json` to `src/native-host/package.json` |
| VER-03 | Installer build reads version from `src/native-host/package.json` | `src/interceptor/build.ps1` lines 98-104 read from repo root — path must change |
| VER-04 | `manifest.json` version auto-synced via lifecycle script on changeset version bump | VER-04 scope: changeset's `version` command bumps `src/extension/package.json`; the existing Vite plugin handles build-time injection. A `postversion` npm script (or Vite plugin at dev-build time) handles dev builds |
</phase_requirements>

---

## Summary

Phase 6 installs the changesets versioning scaffold without triggering any publish steps — publishing is Phase 7+. The work has three independent seams: (1) changesets configuration files, (2) a new `src/native-host/package.json` workspace stub, and (3) build script migrations that swap the version source from root `package.json` to per-package files.

The changesets ecosystem supports this "private packages, no npm publish, create git tags" pattern explicitly via `privatePackages: { version: true, tag: true }` in `.changeset/config.json`. The `changesets/action@v1.7.0` must receive a Fine-Grained PAT (not `GITHUB_TOKEN`) both for checkout and for the action itself — `GITHUB_TOKEN` commits cannot trigger downstream CI workflows by GitHub design.

The most subtle integration is **VER-04**: the source `manifest.json` already uses `"version": "0.0.0-dev"` as a static placeholder. The Vite plugin `stampManifestVersion` already writes the version into the built output — it just currently reads from the wrong path (root `package.json` instead of `src/extension/package.json`). That path fix, plus adding the dev-build prerelease suffix logic, completes VER-01 and VER-04. The E2E workflow (`e2e.yml`) has a hardcoded `2.0.0` in the Go build ldflags (line 51) that must be updated to read from `src/native-host/package.json`.

**Primary recommendation:** Configure changesets with `privatePackages.tag: true`, create the native-host package.json stub, add the changeset CI workflow with PAT, and update all four version-source read sites (two build scripts, one workflow, one Vite plugin).

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| @changesets/cli | 2.30.0 | Changeset authoring and `changeset version` command | Official changesets tooling; only client needed |
| changesets/action | v1.7.0 | GitHub Action that creates Version Packages PR | Pinned per user decision D-04; latest release as of 2026-04-12 |

[VERIFIED: npm registry] `@changesets/cli@2.30.0` — confirmed via `npm view @changesets/cli version`
[VERIFIED: github.com/changesets/action] `v1.7.0` released February 12, 2026 — confirmed via action README

### Supporting (Claude's Discretion)

No additional libraries needed for this phase. The `@changesets/changelog-github` package is NOT installed in this phase — changelogs are deferred (OPS-03).

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `@changesets/cli/changelog` (default) | `@changesets/changelog-github` | GitHub changelog adds PR links; requires `GITHUB_TOKEN` in the `changeset version` step; deferred to OPS-03 |
| Fine-Grained PAT | Classic PAT | Fine-grained is more secure; both work equally for this use case |
| `changesets/action@v1.7.0` | Pinned SHA | SHA pinning is more secure for supply chain; v1.7.0 is acceptable for a solo OSS project |

**Installation:**
```bash
npm install --save-dev @changesets/cli
npx changeset init
```

The `npx changeset init` creates `.changeset/config.json` with defaults that must be overridden (see Architecture Patterns).

---

## Architecture Patterns

### Recommended Project Structure Changes

```
(root)
├── .changeset/
│   ├── config.json          # NEW — changesets configuration
│   └── README.md            # auto-generated by changeset init, keep
├── package.json             # MODIFY: remove "version", add src/native-host to workspaces
├── src/
│   ├── extension/
│   │   ├── package.json     # MODIFY: bump version to 2.1.0
│   │   └── vite.config.ts   # MODIFY: fix version source path, add dev suffix logic
│   ├── native-host/
│   │   └── package.json     # NEW — minimal private workspace stub at 2.1.0
│   └── interceptor/
│       └── build.ps1        # MODIFY: read version from src/native-host/package.json
└── .github/
    └── workflows/
        └── version-packages.yml  # NEW — changesets action CI workflow
```

### Pattern 1: `.changeset/config.json` for private packages with tagging

**What:** Changesets configuration that enables versioning and git-tag creation for private packages, without npm publish.

**When to use:** Always — this is the only config approach that creates `go-mapi-extension@X.Y.Z` and `go-mapi-host@X.Y.Z` tags.

```json
// Source: https://github.com/changesets/changesets/blob/main/docs/config-file-options.md
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

Key points:
- `privatePackages.tag: true` — CRITICAL; default is `false`; without this, no `go-mapi-extension@X.Y.Z` tag is created [VERIFIED: changesets config docs]
- `baseBranch: "main"` — changesets compares against `main` to detect what changed
- `commit: false` — the action handles commits; setting `true` would double-commit
- `changelog: "@changesets/cli/changelog"` — local file format (no GitHub API calls needed for this phase)

### Pattern 2: `src/native-host/package.json` minimal stub

**What:** Minimal npm package descriptor for the native host. Just enough for changesets to track version and create a tag.

**When to use:** New file — does not exist yet.

```json
{
  "name": "go-mapi-host",
  "version": "2.1.0",
  "private": true,
  "description": "go-mapi native messaging host (Windows binary — not published to npm)"
}
```

- No `scripts` needed (build is driven by root `package.json` scripts)
- No `dependencies` needed (Go modules handle dependencies)
- `"private": true` — tells both npm and changesets this is not for registry publishing
- Name `go-mapi-host` matches the intended git tag prefix `go-mapi-host@X.Y.Z`

### Pattern 3: Version Packages CI Workflow

**What:** GitHub Actions workflow that runs `changesets/action@v1.7.0` on pushes to `main`. When changesets exist, the action opens a "Version Packages" PR. When no changesets exist, the action is a no-op.

**When to use:** Runs on every push to `main`.

```yaml
# Source: https://github.com/changesets/action README (adapted)
name: Version Packages

on:
  push:
    branches:
      - main

concurrency:
  group: version-packages-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: write
  pull-requests: write

jobs:
  version:
    name: Create Version PR
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          # CRITICAL: must use PAT, not GITHUB_TOKEN, so the PR creation
          # triggers CI workflows on the Version Packages PR branch.
          token: ${{ secrets.CHANGESET_TOKEN }}
          fetch-depth: 0

      - uses: actions/setup-node@v4
        with:
          node-version: 20

      - name: Install dependencies
        run: npm ci

      - name: Create Version PR or tag releases
        uses: changesets/action@v1.7.0
        with:
          # No `publish` input — this phase only creates the PR.
          # Publishing is Phase 7+.
          commit: "chore: version packages"
          title: "Version Packages"
        env:
          GITHUB_TOKEN: ${{ secrets.CHANGESET_TOKEN }}
```

Notes:
- `runs-on: ubuntu-latest` — the action is shell/git only; no Windows needed for this step
- `fetch-depth: 0` — required so changesets can compare against git history
- PAT passed to BOTH `actions/checkout` (for branch push) AND `env.GITHUB_TOKEN` (for PR creation) [VERIFIED: changesets/action issue #268]
- No `publish` input — omitting it means the action only creates the Version PR; it does not attempt to publish
- The Version Packages PR, when merged to `main`, creates the git tags (because `privatePackages.tag: true`)

### Pattern 4: Vite version plugin update (VER-01 + VER-07 dev suffix)

**What:** Update the existing `stampManifestVersion` Vite plugin to read from `src/extension/package.json` and apply dev suffix for non-production builds.

**Current code (reads from root — WRONG after D-02):**
```typescript
// src/extension/vite.config.ts — CURRENT (broken after D-02)
const rootPkg = JSON.parse(readFileSync(resolve(__dirname, '../../package.json'), 'utf-8'));
manifest.version = rootPkg.version;
```

**Updated code (reads from own package.json, applies CWS-safe version):**
```typescript
// src/extension/vite.config.ts — UPDATED
import { execSync } from 'child_process';

function stampManifestVersion(): Plugin {
  return {
    name: 'stamp-manifest-version',
    writeBundle({ dir }) {
      const extPkg = JSON.parse(readFileSync(resolve(__dirname, 'package.json'), 'utf-8'));
      const manifestPath = resolve(dir!, 'manifest.json');
      const manifest = JSON.parse(readFileSync(manifestPath, 'utf-8'));

      const isProduction = process.env.NODE_ENV === 'production';
      if (isProduction) {
        // CWS requires integer-only semver: strip prerelease and build metadata
        manifest.version = extPkg.version.replace(/[-+].*$/, '');
      } else {
        // Dev builds: {version}-dev+{commithash}
        let hash = 'unknown';
        try {
          hash = execSync('git rev-parse --short HEAD', { encoding: 'utf-8' }).trim();
        } catch { /* not in a git repo, hash stays 'unknown' */ }
        manifest.version = `${extPkg.version.replace(/[-+].*$/, '')}-dev+${hash}`;
      }

      writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
    },
  };
}
```

Notes:
- `resolve(__dirname, 'package.json')` — correct after D-02 (reads `src/extension/package.json`)
- CWS format: strip everything from the first `-` or `+` for production builds [ASSUMED — based on CWS documentation convention; D-07 is the locked decision]
- `process.env.NODE_ENV === 'production'` is set by Vite during `vite build` (production) vs `vite build --watch` (development) [ASSUMED — standard Vite behavior]

### Pattern 5: Build script version source migration

**What:** Update PowerShell one-liners in root `package.json` scripts and `src/interceptor/build.ps1` to read from the per-package `package.json`.

**build:native-host (root package.json) — BEFORE:**
```json
"build:native-host": "powershell -Command \"$v=(Get-Content package.json -Raw|ConvertFrom-Json).version; ...\""
```

**AFTER:**
```json
"build:native-host": "powershell -Command \"$v=(Get-Content src/native-host/package.json -Raw|ConvertFrom-Json).version; cd src/native-host; go build -ldflags \\\"-s -w -X main.Version=$v\\\" -o build/go-mapi-host.exe .\""
```

**build.ps1 (interceptor) — BEFORE (lines 99-104):**
```powershell
$repoRoot = Split-Path -Parent (Split-Path -Parent $interceptorRoot)
$packageJson = Join-Path $repoRoot "package.json"
```

**AFTER:**
```powershell
$repoRoot = Split-Path -Parent (Split-Path -Parent $interceptorRoot)
$packageJson = Join-Path $repoRoot "src\native-host\package.json"
```

The DLL embeds the interceptor version (same as host — they ship together). This is correct: DLL and host are always released as a pair.

**e2e.yml hardcoded version (line 51) — BEFORE:**
```yaml
run: go build -ldflags "-s -w -X main.Version=2.0.0" -o build/go-mapi-host.exe .
```

**AFTER (reads from file, bash-compatible):**
```yaml
run: |
  V=$(jq -r '.version' src/native-host/package.json)
  go build -ldflags "-s -w -X main.Version=$V" -o build/go-mapi-host.exe .
```

### Anti-Patterns to Avoid

- **Omitting `fetch-depth: 0` on checkout**: Changesets needs the full git history to compute what changed since the last release. Shallow clones produce wrong results.
- **Using `GITHUB_TOKEN` for the changesets action**: GitHub intentionally prevents `GITHUB_TOKEN` commits from triggering downstream CI. The Version Packages PR will not get status checks without a PAT. [VERIFIED: changesets/action issue #70]
- **Setting `commit: true` in config.json**: The action already commits; enabling this in config too causes double-commit failures.
- **Using `"private": false` in `src/native-host/package.json`**: Changesets will attempt to publish to the npm registry on `changeset publish`. Keep private.
- **Adding `publish` input to the changesets action workflow**: This phase is scaffold only — no publish step. The `publish` input triggers an npm publish attempt; omit it entirely.
- **Forgetting to add `src/native-host` to root `workspaces`**: Changesets discovers packages via npm workspaces. Without this entry, it ignores `src/native-host/package.json` entirely.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Tracking which changeset files exist | Custom file scanner | `@changesets/cli` changeset detection | Edge cases with concurrent PRs, file format validation |
| Creating Version Packages PRs | Custom GitHub API calls | `changesets/action@v1.7.0` | Branch creation, PR update-or-create logic, commit attribution |
| Version bump logic | Custom semver math | `changeset version` command | Handles `major/minor/patch` correctly, reads all pending changeset files |
| Git tag format for packages | Custom `git tag` calls | `changeset publish` / `changesets.tag` (via action) | Handles `{packageName}@{version}` format, `--no-git-tag-version` compatibility |

**Key insight:** The changeset file format (`.changeset/*.md` with frontmatter) is the canonical input. The CLI parses it; hand-rolling a reader will miss edge cases (bumps that affect multiple packages, pre-release channels).

---

## Common Pitfalls

### Pitfall 1: GITHUB_TOKEN cannot trigger downstream CI
**What goes wrong:** The Version Packages PR is created but never gets its CI status checks, blocking merge forever.
**Why it happens:** GitHub prevents `GITHUB_TOKEN`-authored commits from triggering workflows — intentional anti-loop design.
**How to avoid:** Use a Fine-Grained PAT (`CHANGESET_TOKEN`) for both `actions/checkout` (`with.token`) and the action (`env.GITHUB_TOKEN`). [VERIFIED: changesets/action issue #70, #268]
**Warning signs:** PR created but "Required status checks" show "Waiting" indefinitely; no new workflow runs visible for the Version Packages PR branch.

### Pitfall 2: `privatePackages.tag` defaults to `false`
**What goes wrong:** `changeset version` bumps versions but no `go-mapi-extension@2.1.0` or `go-mapi-host@2.1.0` git tags are created.
**Why it happens:** Changesets's default config omits `privatePackages` entirely, and the default for `tag` is `false`.
**How to avoid:** Explicitly set `"privatePackages": { "version": true, "tag": true }` in `.changeset/config.json`. [VERIFIED: changesets config docs]
**Warning signs:** `git tag -l "go-mapi*"` shows nothing after merging the Version Packages PR.

### Pitfall 3: Root `package.json` still has version field after D-02
**What goes wrong:** The Vite plugin or build scripts silently fall back to the root `package.json` and use the old version.
**Why it happens:** Stale code reading the root file even after migration.
**How to avoid:** Remove `"version"` from root `package.json` (D-02) immediately — this causes a parse error if any script still reads it and tries to use a `null` version, surfacing the bug fast.
**Warning signs:** `manifest.json` in built extension shows `2.0.0` instead of `2.1.0`; `--version` flag on Go binary shows old version.

### Pitfall 4: `npm install` fails after adding `src/native-host` to workspaces
**What goes wrong:** `npm ci` fails because `src/native-host/package.json` doesn't exist yet, or lockfile is out of sync.
**Why it happens:** npm workspaces require all workspace directories to have `package.json` before `npm install` runs.
**How to avoid:** Create `src/native-host/package.json` and run `npm install` (then commit updated `package-lock.json`) as part of the same wave.
**Warning signs:** `npm ci` exits with "missing workspace package" error in CI.

### Pitfall 5: CWS rejects manifest version with prerelease suffix
**What goes wrong:** Extension upload to Chrome Web Store fails with "Invalid version" error.
**Why it happens:** CWS requires integer-only version strings (`2.1.0`); it rejects `2.1.0-dev+abc123`.
**How to avoid:** Vite plugin strips `-dev+{hash}` suffix in production builds (D-07). Source `manifest.json` already uses `"0.0.0-dev"` as placeholder — Vite always overwrites it.
**Warning signs:** `manifest.json` in `src/extension/dist/` contains a hyphen.

### Pitfall 6: `e2e.yml` hardcoded version not updated
**What goes wrong:** E2E tests run with the Go host binary reporting `2.0.0` even though the canonical version is now `2.1.0`.
**Why it happens:** `e2e.yml` line 51 has `go build -ldflags "-s -w -X main.Version=2.0.0"` hardcoded.
**How to avoid:** Update `e2e.yml` to read version from `src/native-host/package.json` using `jq`. [VERIFIED: codebase inspection]
**Warning signs:** E2E test assertions on version string fail or report stale version.

---

## Code Examples

### Verified patterns from official sources

### Example 1: `changeset add` workflow (developer usage)
```bash
# Source: @changesets/cli README
# Run in repo root to create a new changeset file in .changeset/
npx changeset add
# Prompts: which packages changed? major/minor/patch? summary?
# Creates .changeset/{random-name}.md with frontmatter like:
# ---
# "go-mapi-extension": minor
# ---
# "Description of the change"
```

### Example 2: Check what changesets exist
```bash
# Source: @changesets/cli README
npx changeset status
# Shows pending changesets and what version bumps they will produce
```

### Example 3: Apply changesets locally (simulate what the PR does)
```bash
# Source: @changesets/cli README
npx changeset version
# Consumes .changeset/*.md, bumps package.json versions, updates CHANGELOG.md
# Use for local testing only — CI does this via the action
```

### Example 4: Read package.json version from bash (for CI)
```bash
# Source: CLAUDE.md prefer-jq rule (project convention)
# jq -r avoids piping through cat
V=$(jq -r '.version' src/native-host/package.json)
echo "Version: $V"
```

### Example 5: Read package.json version from PowerShell (for build scripts)
```powershell
# Source: existing build.ps1 pattern (lines 101-104) — path updated
$packageJson = Join-Path $repoRoot "src\native-host\package.json"
$goMapiVersion = "0.0.0-dev"
if (Test-Path $packageJson) {
    $pkg = Get-Content $packageJson -Raw | ConvertFrom-Json
    $goMapiVersion = $pkg.version
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Single root `package.json` version | Per-package `package.json` version | Phase 6 (this phase) | Build scripts must update source path |
| `v*` git tag format | `go-mapi-extension@X.Y.Z` / `go-mapi-host@X.Y.Z` | Phase 6 (this phase) | `installer-release.yml` tag trigger becomes stale (Phase 8 converts to dispatch) |
| `GITHUB_TOKEN` for CI operations | Fine-Grained PAT (`CHANGESET_TOKEN`) | Phase 6 (this phase) | PAT must be provisioned as a repo secret before workflow runs |
| Manual version bump | `changeset version` command via PR | Phase 6 (this phase) | Developers must create `.changeset/*.md` files instead of editing package.json |

**Deprecated/outdated:**
- Root `package.json` `"version"` field: Removed in this phase (D-02). After this phase, version authority is per-package only.
- `v*` tag triggers in `installer-release.yml`: Still present (tag trigger is secondary path alongside `workflow_dispatch`), but no new `v*` tags will be created. Will be cleaned up in Phase 8.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `process.env.NODE_ENV === 'production'` is set by Vite when running `vite build` (non-watch) | Pattern 4 (Vite plugin) | Dev builds get production version format; easy to fix via explicit `--mode` flag |
| A2 | CWS requires integer-only semver with no prerelease/build metadata | Pattern 4, Pitfall 5 | Extension upload fails; fix is to verify against actual CWS upload API |
| A3 | `changesets/action` with no `publish` input creates the Version PR but does NOT create git tags (tags are created only when `publish` command is run) | Pattern 3, CS-04 | Tags never created; workaround: add `publish: npx changeset tag` to the action |

**Note on A3:** This is the most important assumption. The `changesets/action` documentation is ambiguous on exactly when git tags are created for private packages (no npm publish step). The `publish` input triggers the `changeset publish` command which creates tags as a side effect. Without a `publish` input, the action only creates the Version Packages PR. If CS-04 (per-package tags) must be created by this phase's workflow, the action may need `publish: npx changeset tag` added. This should be validated during implementation. If tags are only needed at actual publish time (Phases 7/8), omitting `publish` is correct for Phase 6.

---

## Open Questions

1. **Tag creation timing: Phase 6 or Phase 7/8?**
   - What we know: CS-04 requires per-package tags. Phase 6 success criterion 1 says "triggers a Version Packages PR that bumps only `src/extension/package.json` and generates a git tag" — implying the tag is part of Phase 6.
   - What's unclear: Does the tag get created when the Version Packages PR is *created* or when it is *merged*? The changesets action creates the PR when changesets arrive; the tag would normally be created during `changeset publish` after the PR merges.
   - Recommendation: Add `publish: npx changeset tag` to the workflow that runs AFTER the Version PR merges on `main` — that is, a separate job triggered by detecting that the "Version Packages" PR was merged, or simply running the `changeset tag` command in the same workflow that merges. If Phase 6 scope only requires the PR creation workflow, tags can be deferred to Phase 7/8. Confirm with user before planning.

2. **`CHANGESET_TOKEN` PAT ownership**
   - What we know: PAT must belong to a GitHub user with write access to the repo.
   - What's unclear: Whether Marc uses his own account's PAT or a separate bot account.
   - Recommendation: Use Marc's own account PAT (`marcfargas`). Document the required scopes in the plan task so Marc can create it.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Node.js / npm | `@changesets/cli` install | ✓ | Node 18+ (per CLAUDE.md) | — |
| jq | CI version reading in e2e.yml | ✓ | Available on ubuntu-latest GitHub runners | Use `node -e "require('fs').readFileSync"` |
| `@changesets/cli` | changeset add / version commands | ✗ (not yet installed) | — | Install as devDependency |
| Fine-Grained PAT `CHANGESET_TOKEN` | CI version-packages.yml | ✗ (not yet provisioned) | — | No fallback — must be created manually |

**Missing dependencies with no fallback:**
- `CHANGESET_TOKEN` GitHub secret: Must be created by Marc as a Fine-Grained PAT before the CI workflow can run. Required permissions: `Contents: Read and write`, `Pull requests: Read and write`, repository scope: `go-mapi` only.

**Missing dependencies with fallback:**
- `@changesets/cli`: Install via `npm install --save-dev @changesets/cli` (Wave 0 task).

---

## Sources

### Primary (HIGH confidence)
- [changesets/changesets config-file-options.md](https://github.com/changesets/changesets/blob/main/docs/config-file-options.md) — `privatePackages.tag` option, `baseBranch`, all config keys
- [changesets/action README](https://github.com/changesets/action) — action inputs, outputs, `v1.7.0` release date
- npm registry — `@changesets/cli@2.30.0` confirmed current version
- Project codebase — all existing file paths, current code patterns, hardcoded versions

### Secondary (MEDIUM confidence)
- [changesets/action issue #70](https://github.com/changesets/action/issues/70) — GITHUB_TOKEN cannot trigger downstream CI (confirmed by GitHub design)
- [changesets/action issue #268](https://github.com/changesets/action/issues/268) — Fine-grained PAT minimum permissions (`contents: write`, `pull-requests: write`)
- [changesets/changesets discussion #1230](https://github.com/changesets/changesets/discussions/1230) — pattern for non-npm publish (Docker images) with changesets

### Tertiary (LOW confidence)
- [changesets/changesets issue #1111](https://github.com/changesets/changesets/issues/1111) — private packages with GitHub releases (no definitive resolution found)

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — npm registry confirmed `@changesets/cli@2.30.0`; changesets/action `v1.7.0` confirmed from GitHub
- Architecture: HIGH — config options verified from official docs; code patterns inspected directly from codebase
- Pitfalls: HIGH — GITHUB_TOKEN limitation verified from GitHub's own issue tracker; `privatePackages.tag` default verified from config docs
- Assumption A3 (tag creation timing): MEDIUM — ambiguity in action docs; open question flagged

**Research date:** 2026-04-12
**Valid until:** 2026-05-12 (changesets is stable; action releases infrequently)
