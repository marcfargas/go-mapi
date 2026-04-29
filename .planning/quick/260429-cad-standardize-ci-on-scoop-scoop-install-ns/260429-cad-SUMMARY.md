---
quick_id: 260429-cad
description: "Standardize CI on scoop for NSIS installation (drop choco fallback) and fix stale build/ paths in build.yml"
date: "2026-04-29"
subsystem: ci
tags: [ci, nsis, scoop, build-paths, windows-2025]
files_modified:
  - .github/workflows/build.yml
  - .github/workflows/installer-smoke.yml
  - .github/workflows/installer-release.yml
decisions:
  - "Canonical NSIS install uses scoop extras bucket; scoop is already present from the mingw-mstorsjo-llvm-ucrt install step so no additional scoop bootstrap is needed"
  - "NSIS install step and Compile installer step are kept separate (two run: blocks) because scoop PATH propagates between pwsh steps via user PATH shims; no refreshenv needed"
  - "build/ → build-x64/ is a mechanical rename: no -Arch arg is passed to build.ps1 so it defaults to x64, outputting to build-x64/"
---

# Quick Task 260429-cad Summary

**One-liner:** Drop choco NSIS fallback in both installer workflows; replace with `scoop extras bucket + scoop install nsis` split step; fix four stale `build/` → `build-x64/` path references in build.yml.

## What Changed

- **installer-smoke.yml**: Replaced `Verify NSIS is available (pre-installed on windows-latest)` step (choco try/catch) with canonical `Install NSIS via scoop (extras bucket)` step. The existing `Compile installer` step was unchanged.
- **installer-release.yml**: Replaced single combined `Verify NSIS + compile installer` step (choco try/catch + makensis in one run block) with two separate steps: `Install NSIS via scoop (extras bucket)` + `Compile installer` (preserving `/DGOMAPI_VERSION=${{ steps.version.outputs.version }}`).
- **build.yml**: Renamed `build/` to `build-x64/` in four locations: `Run Test Harness` run command, `Run C++ Unit Tests` working-directory, `Upload DLL Artifact` path, `Upload Test Harness Artifact` path.

## Why

Two CI failures surfaced after the 260429-b4l toolchain fix landed on windows-latest (now windows-2025):

1. **NSIS not pre-installed on windows-2025**: The old `try { makensis /VERSION } catch { choco install nsis }` pattern installed NSIS in the same run block as the compile step in installer-release.yml, but in installer-smoke.yml the install ran in a *separate* pwsh step from `Compile installer`. When choco installs a tool it does not refresh the current pwsh session's PATH — the next separate `run:` block starts fresh and `makensis` remains "not recognized". Scoop adds shims to user PATH at install time, and GitHub Actions pwsh sessions inherit user PATH between steps in the same job, so the separate-step pattern works correctly.

2. **Stale `build/` paths in build.yml**: QUICK-260423-ntu changed `build.ps1` to output binaries to `build-$Arch` (defaulting to `build-x64` when no `-Arch` arg is passed). The four downstream steps in `build-interceptor` job that consume those outputs were never updated and still referenced `build/bin/`, causing "directory name is invalid" failures.

## Verification

Local YAML parse checks:
```
node -e "require('js-yaml').load(require('fs').readFileSync(f,'utf8'))"
```
All three files: OK.

Grep checks:
- No `choco install nsis` references in either installer workflow: PASS
- No `src/interceptor/build/` (stale) references in build.yml: PASS
- Both installer workflows contain `scoop bucket add extras` + `scoop install nsis`: PASS
- installer-release.yml Compile step still passes `/DGOMAPI_VERSION=${{ steps.version.outputs.version }}`: PASS

Actual CI run verification (workflows passing on windows-2025) requires a push, which is intentionally out of scope per plan constraints. The user will push manually after reviewing the commit.

## Follow-ups

None. The following are explicitly out of scope:
- Caching scoop installs across runs
- actions/checkout v5 bump
- x86 build matrix in build.yml
- The cosmetic `Restore cache failed` warning in installer-smoke
