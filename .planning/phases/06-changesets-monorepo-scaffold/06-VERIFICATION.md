---
phase: 06-changesets-monorepo-scaffold
verified: 2026-04-12T00:00:00Z
status: human_needed
score: 10/10 must-haves verified (structural); 5 roadmap success criteria require live CI/build verification
overrides_applied: 0
human_verification:
  - test: "Push a changeset file targeting src/extension to main and observe the Actions tab"
    expected: "Version Packages workflow runs, creates a PR titled 'Version Packages' that bumps src/extension/package.json only"
    why_human: "Requires CHANGESET_TOKEN secret to be set in repo, live GitHub Actions run, and real PR creation — cannot simulate locally"
  - test: "Push a changeset file targeting src/native-host to main and observe the Actions tab"
    expected: "Version Packages workflow runs, creates a PR titled 'Version Packages' that bumps src/native-host/package.json only"
    why_human: "Same as above — requires live CI run on main branch with changesets present"
  - test: "Run 'npm run build:native-host' and check the READY message version"
    expected: "READY message HostVersion field reports '2.1.0' (matching src/native-host/package.json)"
    why_human: "Requires Go toolchain (MinGW + Go 1.21) and running the compiled binary; cannot compile on verification runner"
  - test: "Run 'npm run build:extension' and inspect src/extension/dist/manifest.json"
    expected: "manifest.json version field is '2.1.0' (no prerelease suffix, CWS-compliant)"
    why_human: "Requires Node 18+, Vite build, TypeScript compilation — build environment not confirmed in this session"
  - test: "Confirm CHANGESET_TOKEN secret is present in GitHub repo settings"
    expected: "CHANGESET_TOKEN visible in https://github.com/marcfargas/go-mapi/settings/secrets/actions"
    why_human: "GitHub repo secrets are not readable via CLI without auth; Marc confirmed creation on 2026-04-12 in 06-03-SUMMARY.md but cannot be verified programmatically"
---

# Phase 6: Changesets Monorepo Scaffold Verification Report

**Phase Goal:** Version authority lives in per-package package.json files, changesets is configured with two independent tracks, and a Version Packages PR is auto-created when changesets exist on main
**Verified:** 2026-04-12
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

All plan must-haves verified structurally. Five roadmap success criteria require live execution (human verification).

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Changesets installed and configured for two private workspace packages | VERIFIED | `.changeset/config.json` has `privatePackages.tag: true`, `baseBranch: main`, `commit: false`; `@changesets/cli@2.30.0` in package-lock.json |
| 2 | `src/native-host/package.json` exists as workspace package at version 2.1.0 | VERIFIED | File exists with `name: go-mapi-host`, `version: 2.1.0`, `private: true`; lockfile entry at `src/native-host` confirms 2.1.0 |
| 3 | `src/extension/package.json` is at version 2.1.0 | VERIFIED | `jq .version src/extension/package.json` returns `"2.1.0"`; lockfile entry at `src/extension` confirms 2.1.0 |
| 4 | Root `package.json` has no version field | VERIFIED | `jq .version package.json` returns `null`; workspaces field is `["src/extension", "src/native-host"]` |
| 5 | Go host build reads version from `src/native-host/package.json` | VERIFIED | `build:native-host` and `build:native-host:debug` scripts use `Get-Content src/native-host/package.json`; commit ca72550 |
| 6 | Interceptor DLL build reads version from `src/native-host/package.json` | VERIFIED | `src/interceptor/build.ps1` line 100: `$packageJson = Join-Path $repoRoot "src\native-host\package.json"`; commit ca72550 |
| 7 | E2E workflow reads version from `src/native-host/package.json` dynamically | VERIFIED | `.github/workflows/e2e.yml` uses `jq -r '.version' package.json` with `working-directory: src/native-host`; no `Version=2.0.0` hardcoding remains; commit 881fe06 |
| 8 | Extension build reads version from `src/extension/package.json` | VERIFIED | `vite.config.ts` reads `resolve(__dirname, 'package.json')` — same directory as vite.config.ts (`src/extension/`); no `../../package.json` reference; commit 1d17c55 |
| 9 | Production extension builds produce CWS-compliant integer-only version | VERIFIED (code) | `vite.config.ts` strips prerelease via `.replace(/[-+].*$/, '')` under `NODE_ENV === 'production'`; dev builds append `-dev+{commithash}` |
| 10 | Version Packages PR workflow created with correct structure | VERIFIED | `.github/workflows/version-packages.yml` exists with `changesets/action@v1.7.0`, `CHANGESET_TOKEN` PAT in both checkout and `env.GITHUB_TOKEN`, `fetch-depth: 0`, `concurrency`, `permissions: contents: write + pull-requests: write`, no `publish:` input |

**Score:** 10/10 structural truths verified

### Roadmap Success Criteria

| # | Success Criterion | Status | Notes |
|---|-------------------|--------|-------|
| SC-1 | Extension changeset on main triggers Version Packages PR bumping only extension | HUMAN NEEDED | Workflow code is correct; requires live CI run with CHANGESET_TOKEN secret |
| SC-2 | Host changeset on main triggers Version Packages PR bumping only host | HUMAN NEEDED | Same — requires live CI run |
| SC-3 | Go host binary reports version from `src/native-host/package.json` | HUMAN NEEDED | Code reads correct file; build output verification needs Go toolchain |
| SC-4 | Vite extension build embeds version from `src/extension/package.json` in manifest.json | HUMAN NEEDED | Plugin code is correct; actual build output verification needed |
| SC-5 | Inno Setup installer embeds version from `src/native-host/package.json` | PARTIAL (see note) | DLL build (interceptor/build.ps1) reads native-host/package.json; installer-release.yml reads version from git tag/workflow_dispatch input — tags flow from changesets bumping native-host/package.json, so version chain is correct but indirect |

**Note on SC-5 and VER-03:** The REQUIREMENTS.md says "Installer build reads version from `src/native-host/package.json`." Per RESEARCH.md (line 49), VER-03 maps specifically to `src/interceptor/build.ps1` (the C++ DLL build script), which was updated. The Inno Setup `installer-release.yml` CI workflow gets its version from `workflow_dispatch` input or git tags — tags that originate from changeset-bumped `src/native-host/package.json`. The version chain is correct for the intended Phase 6 scope. Full end-to-end installer version tracing from package.json → tag → installer binary will be validated in Phase 8.

**Note on CS-04 (per-package git tags):** The tag format `go-mapi-extension@X.Y.Z` / `go-mapi-host@X.Y.Z` is configured via `privatePackages.tag: true` in `.changeset/config.json`. Actual tag creation requires the Version Packages PR to merge AND a `publish:` input in the workflow — deliberately omitted in Phase 6 per plan design decisions (D-05). Tag creation is completed in Phases 7/8 when the publish step is added. This is an intentional scaffold-phase constraint, not a gap.

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `.changeset/config.json` | Changesets config with privatePackages tag | VERIFIED | `privatePackages.tag: true`, `baseBranch: main`, `commit: false` |
| `.changeset/README.md` | Auto-generated changeset README | VERIFIED | Created by `changeset init` |
| `src/native-host/package.json` | Host version tracking stub | VERIFIED | `name: go-mapi-host`, `version: 2.1.0`, `private: true` |
| `package.json` | Root workspace config without version field | VERIFIED | No version field; workspaces: `["src/extension", "src/native-host"]` |
| `src/extension/package.json` | Extension package at 2.1.0 | VERIFIED | `version: 2.1.0` |
| `package-lock.json` | Lockfile with both workspaces | VERIFIED | Both `src/native-host` and `src/extension` at 2.1.0 in lockfile |
| `src/interceptor/build.ps1` | DLL build reading host version | VERIFIED | Line 100 reads `src\native-host\package.json` |
| `.github/workflows/e2e.yml` | E2E workflow with dynamic version | VERIFIED | `jq -r '.version' package.json` with `working-directory: src/native-host` |
| `src/extension/vite.config.ts` | Vite plugin reading extension version | VERIFIED | `resolve(__dirname, 'package.json')` + `execSync` + dev suffix + production strip |
| `.github/workflows/version-packages.yml` | Version Packages CI workflow | VERIFIED | `changesets/action@v1.7.0`, `CHANGESET_TOKEN`, `fetch-depth: 0`, `concurrency` |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `package.json` workspaces | `src/native-host/package.json` | workspaces array | WIRED | `["src/extension", "src/native-host"]` — both resolved in lockfile |
| `.changeset/config.json` | workspace packages | `baseBranch: main` + `privatePackages` | WIRED | Config discovered via npm workspace root; both packages are private |
| `package.json build:native-host` | `src/native-host/package.json` | PowerShell `Get-Content src/native-host/package.json` | WIRED | Confirmed in package.json lines 13-14 |
| `src/interceptor/build.ps1` | `src/native-host/package.json` | `Join-Path $repoRoot "src\native-host\package.json"` | WIRED | Line 100 confirmed |
| `.github/workflows/e2e.yml` | `src/native-host/package.json` | `jq -r '.version' package.json` in `working-directory: src/native-host` | WIRED | Line 52 confirmed; no hardcoded version remains |
| `src/extension/vite.config.ts` | `src/extension/package.json` | `readFileSync(resolve(__dirname, 'package.json'))` | WIRED | Line 11 confirmed; no `../../package.json` reference |
| `.github/workflows/version-packages.yml` | `CHANGESET_TOKEN` secret | `secrets.CHANGESET_TOKEN` in checkout token + env.GITHUB_TOKEN | WIRED (code) | Secret reference correct; secret existence confirmed by user on 2026-04-12 |
| `.github/workflows/version-packages.yml` | `.changeset/config.json` | `changesets/action@v1.7.0` reads config on install | WIRED | Action reads config from repo root `.changeset/` directory |

### Behavioral Spot-Checks

| Behavior | Check | Result | Status |
|----------|-------|--------|--------|
| `@changesets/cli` installed | `jq '.packages["node_modules/@changesets/cli"].version' package-lock.json` | `2.30.0` | PASS |
| Both workspaces in lockfile | `jq '.packages | keys | map(select(contains("go-mapi")))' package-lock.json` | `["node_modules/go-mapi-extension", "node_modules/go-mapi-host", "src/extension", "src/native-host"]` | PASS |
| No hardcoded version in e2e.yml | `grep "Version=2.0.0" .github/workflows/e2e.yml` | No output | PASS |
| vite.config.ts: no root ref | `grep "../../package.json" src/extension/vite.config.ts` | No output | PASS |
| version-packages.yml: no publish | `grep "publish:" .github/workflows/version-packages.yml` | No output | PASS |
| All 6 commits exist in git | `git log --oneline 58bfabe 9c83596 ca72550 881fe06 1d17c55 d802e31` | All 6 found | PASS |
| Root package.json: no version field | `jq .version package.json` | `null` | PASS |
| Extension at 2.1.0 | `jq .version src/extension/package.json` | `"2.1.0"` | PASS |
| Native host at 2.1.0 | `jq .version src/native-host/package.json` | `"2.1.0"` | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| CS-01 | 06-01 | Changesets configured with `privatePackages.tag: true` | SATISFIED | `.changeset/config.json` verified |
| CS-02 | 06-01 | `src/native-host/package.json` stub created | SATISFIED | File exists with correct content |
| CS-03 | 06-01 | Root `package.json` workspaces includes both packages | SATISFIED | `workspaces: ["src/extension", "src/native-host"]` confirmed |
| CS-04 | 06-03 | Independent semver tracks with per-package git tags | SATISFIED (infrastructure) | Config enables tags via `privatePackages.tag: true`; tag creation requires publish step added in Phase 7/8 — by design |
| CS-05 | 06-03 | `CHANGESET_TOKEN` PAT configured as repo secret | SATISFIED (user-confirmed) | User confirmed PAT creation on 2026-04-12; programmatic verification impossible for secrets |
| CS-06 | 06-03 | Version Packages PR auto-created by `changesets/action@v1.7.0` | SATISFIED (structural) | Workflow exists and is correctly configured; live execution is human verification item |
| VER-01 | 06-02 | Extension build reads version from `src/extension/package.json` | SATISFIED | `vite.config.ts` reads `resolve(__dirname, 'package.json')` |
| VER-02 | 06-02 | Go host build reads version from `src/native-host/package.json` | SATISFIED | `build:native-host` scripts and e2e.yml confirmed |
| VER-03 | 06-02 | Installer build reads version from `src/native-host/package.json` | SATISFIED | `src/interceptor/build.ps1` reads `src\native-host\package.json` per RESEARCH.md mapping |
| VER-04 | 06-02 | `manifest.json` version auto-synced with prerelease strip | SATISFIED | `vite.config.ts` plugin strips with `.replace(/[-+].*$/, '')` in production; dev builds add `-dev+{commithash}` |

All 10 requirements from plans 06-01, 06-02, 06-03 are accounted for. No orphaned requirements for Phase 6.

**Orphan check:** REQUIREMENTS.md traceability table maps CS-01 through CS-06, VER-01 through VER-04 to Phase 6. All 10 are covered across 3 plans. No Phase 6 requirements appear in REQUIREMENTS.md that are missing from plan frontmatter.

### Anti-Patterns Found

No blockers or warnings detected across modified files:

| File | Pattern | Severity | Assessment |
|------|---------|----------|------------|
| `scripts/package-extension.ps1` line 11 | Reads version from `package.json` (root) | Info | Root `package.json` has no version field; this script will fail with `$null` version when invoked. However, this script is not in Phase 6 scope (not listed in any plan's `files_modified`) and is used for manual CWS packaging — Phase 7 will address it. Not a Phase 6 blocker. |

**`scripts/package-extension.ps1` note:** This script reads `(Get-Content ..\package.json).version` which will now produce `$null` since the root version field was removed in Plan 01 (D-02). This is a pre-existing script outside Phase 6 scope. Phase 7 (Extension Publishing Pipeline) will update or replace this script. Flagged as informational.

### Human Verification Required

#### 1. Version Packages Workflow — Extension Changeset

**Test:** Add a changeset file (`npx changeset`) targeting `go-mapi-extension`, push a commit to `main`, and observe GitHub Actions
**Expected:** The "Version Packages" workflow triggers, creates a PR titled "Version Packages" that bumps only `src/extension/package.json` and a git tag `go-mapi-extension@2.2.0` (or whatever the bumped version is)
**Why human:** Requires CHANGESET_TOKEN secret to be active, live push to main branch, and real GitHub Actions execution

#### 2. Version Packages Workflow — Host Changeset

**Test:** Add a changeset file targeting `go-mapi-host`, push to `main`, observe GitHub Actions
**Expected:** Version Packages PR bumps only `src/native-host/package.json`, git tag `go-mapi-host@X.Y.Z` created on PR merge
**Why human:** Same as above — requires live CI run

#### 3. Go Host Binary Version String

**Test:** Run `npm run build:native-host` and then start the host; observe the READY message in the native messaging log
**Expected:** `HostVersion: "2.1.0"` in the READY message
**Why human:** Requires Go toolchain (Go 1.21 + MinGW) and Windows runtime to compile and execute the binary

#### 4. Extension Build — Manifest Version

**Test:** Run `npm run build:extension` and inspect `src/extension/dist/manifest.json`
**Expected:** `"version": "2.1.0"` (no prerelease suffix) since production build strips with `.replace(/[-+].*$/)`
**Why human:** Requires Node 18+, Vite, TypeScript — build environment needed

#### 5. CHANGESET_TOKEN Secret Existence

**Test:** Navigate to `https://github.com/marcfargas/go-mapi/settings/secrets/actions`
**Expected:** `CHANGESET_TOKEN` appears in the repository secrets list
**Why human:** GitHub repo secrets are not accessible via API without authentication; user confirmed creation on 2026-04-12

### Gaps Summary

No blocking gaps identified. All structural must-haves are verified in the codebase. The 5 human verification items above are required to confirm live behavior — they cannot be checked programmatically.

One informational item: `scripts/package-extension.ps1` reads root `package.json` for version, which will return `$null` since the root version field was removed. This is outside Phase 6 scope and will be fixed in Phase 7.

---

_Verified: 2026-04-12_
_Verifier: Claude (gsd-verifier)_
