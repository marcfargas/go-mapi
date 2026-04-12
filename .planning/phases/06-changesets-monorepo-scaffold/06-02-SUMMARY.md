---
phase: 06-changesets-monorepo-scaffold
plan: 02
subsystem: versioning
tags: [versioning, build-scripts, vite, github-actions, dev-suffix]
dependency_graph:
  requires: [06-01]
  provides: [per-package-version-reads, cws-compliant-extension-version, dev-build-suffix]
  affects: [package.json, src/interceptor/build.ps1, .github/workflows/e2e.yml, src/extension/vite.config.ts]
tech_stack:
  added: []
  patterns: [per-package-version-authority, cws-integer-semver, git-rev-parse-dev-suffix]
key_files:
  created: []
  modified:
    - package.json
    - src/interceptor/build.ps1
    - .github/workflows/e2e.yml
    - src/extension/vite.config.ts
decisions:
  - "DLL and host share version from src/native-host/package.json — they ship as a pair, same version track"
  - "Dev builds use -dev+{commithash} suffix (execSync git rev-parse --short HEAD) for local identification"
  - "Production builds strip prerelease metadata via replace(/[-+].*$/) to produce CWS-compliant X.Y.Z"
  - "e2e.yml uses jq (project prefer-jq rule) reading relative package.json from working-directory: src/native-host"
metrics:
  duration: "5 minutes"
  completed: "2026-04-12"
  tasks_completed: 3
  files_created: 0
  files_modified: 4
requirements: [VER-01, VER-02, VER-03, VER-04]
---

# Phase 6 Plan 2: Version Source Migration Summary

**One-liner:** All four version-read sites migrated from root package.json to per-package files; extension Vite plugin adds CWS-compliant production version and dev+commithash suffix for dev builds.

## Tasks Completed

| # | Task | Commit | Files |
|---|------|--------|-------|
| 1 | Update build scripts to read from per-package package.json | ca72550 | package.json, src/interceptor/build.ps1 |
| 2 | Update e2e.yml to read version dynamically | 881fe06 | .github/workflows/e2e.yml |
| 3 | Update Vite plugin for per-package version and dev suffix | 1d17c55 | src/extension/vite.config.ts |

## What Was Built

- **`package.json` build scripts** — `build:native-host` and `build:native-host:debug` now read version from `src/native-host/package.json` instead of the (now-removed) root `package.json` version field. Previously would have resolved to `undefined` after Plan 06-01 removed the root version.

- **`src/interceptor/build.ps1`** — `$packageJson` path changed from `$repoRoot\package.json` to `$repoRoot\src\native-host\package.json`. DLL and host ship as a pair with the same version (native-host package is the shared version authority for both).

- **`.github/workflows/e2e.yml`** — Replaced hardcoded `Version=2.0.0` in the "Build native host" step with dynamic `jq -r '.version' package.json` read (working-directory is already `src/native-host`, so relative path resolves correctly). Follows project prefer-jq rule.

- **`src/extension/vite.config.ts`** — Rewrote `stampManifestVersion` Vite plugin:
  - Now reads `src/extension/package.json` (own directory via `resolve(__dirname, 'package.json')`) instead of root `../../package.json`
  - Added `execSync` import from `child_process`
  - Production builds (`NODE_ENV === 'production'`): strips prerelease/build metadata with `.replace(/[-+].*$/, '')` for CWS-compliant `X.Y.Z` integer-only format
  - Dev builds: appends `-dev+{commithash}` using `git rev-parse --short HEAD` (wrapped in try/catch for non-git environments)

## Verification Results

| Check | Result |
|-------|--------|
| `package.json` contains `src/native-host/package.json` in build scripts | PASS |
| `src/interceptor/build.ps1` reads from `src\native-host\package.json` | PASS |
| `.github/workflows/e2e.yml` contains `jq -r '.version' package.json` | PASS |
| `.github/workflows/e2e.yml` has no `Version=2.0.0` | PASS |
| `src/extension/vite.config.ts` reads `resolve(__dirname, 'package.json')` | PASS |
| `src/extension/vite.config.ts` has no `../../package.json` reference | PASS |
| `src/extension/vite.config.ts` imports `execSync` | PASS |
| `src/extension/vite.config.ts` contains `-dev+` suffix logic | PASS |
| `src/extension/vite.config.ts` contains `process.env.NODE_ENV === 'production'` | PASS |

## Deviations from Plan

None - plan executed exactly as written.

## Known Stubs

None — no placeholder text or empty data sources introduced.

## Threat Flags

None beyond what is documented in the plan's threat model:
- `T-06-03`: `execSync` in `vite.config.ts` — accepted; build-time only, hardcoded command, wrapped in try/catch.
- `T-06-04`: version field read from committed `package.json` — accepted; tampering visible in git diff.

## Self-Check: PASSED

- Commit `ca72550` — FOUND (package.json + build.ps1)
- Commit `881fe06` — FOUND (e2e.yml)
- Commit `1d17c55` — FOUND (vite.config.ts)
- All 4 modified files present in worktree — VERIFIED
