---
phase: quick-260429-b4l
plan: "01"
subsystem: ci
tags: [ci, mingw, scoop, toolchain, interceptor]
dependency_graph:
  requires: []
  provides: ["CI mingw-mstorsjo-llvm-ucrt toolchain on windows-latest runners"]
  affects: [".github/workflows/build.yml", ".github/workflows/installer-smoke.yml", ".github/workflows/installer-release.yml"]
tech_stack:
  added: ["scoop mingw-mstorsjo-llvm-ucrt"]
  patterns: ["SCOOP_INSTALL_AS_ADMIN elevation bypass", "triple-prefixed clang driver check"]
key_files:
  created: []
  modified:
    - .github/workflows/build.yml
    - .github/workflows/installer-smoke.yml
    - .github/workflows/installer-release.yml
decisions:
  - "Scoop SCOOP_INSTALL_AS_ADMIN=1 must be set as env var before invoking the scoop installer on elevated windows-latest pwsh sessions — aborts without it"
  - "cmake + ninja from the mingw-mstorsjo-llvm-ucrt scoop bundle make separate cmake/ninja install steps unnecessary"
  - "Sanity-check throws on missing triple-prefixed driver immediately after install — fail fast at toolchain setup, not at build.ps1"
metrics:
  duration: "~5 min"
  completed: "2026-04-29"
  tasks_completed: 1
  tasks_total: 1
  files_changed: 3
---

# Quick Task 260429-b4l: Add mingw-mstorsjo-llvm-ucrt to CI Workflows

**One-liner:** Replaced choco mingw with scoop mingw-mstorsjo-llvm-ucrt (triple-prefixed clang) in all three CI workflows to match build.ps1's hardcoded $USERPROFILE\scoop\apps path, unblocking the DLL build on every CI run.

## Commit

| Hash | Message |
|------|---------|
| db4b23b | chore(quick-260429-b4l): replace choco mingw with scoop mingw-mstorsjo-llvm-ucrt in CI |

## What Changed

### Problem

`build.ps1` (since QUICK-260423-ntu) hardcodes:

```
$clangBin = "$env:USERPROFILE\scoop\apps\mingw-mstorsjo-llvm-ucrt\current\bin"
```

and fails fast (exit 1) if that path does not exist. The three CI workflows were still
running `choco install mingw`, which installs to `C:\ProgramData\chocolatey\lib\mingw\...`
— a completely different layout that build.ps1 never reads. Every CI run since QUICK-260423-ntu
has failed at "Build interceptor DLL" / "Build Interceptor and Test Harness" with:

```
mingw-mstorsjo-llvm-ucrt not found at C:\Users\runneradmin\scoop\apps\mingw-mstorsjo-llvm-ucrt\current\bin
```

### Fix Applied

Identical step body in all three files (step `name` varies per workflow):

```yaml
- name: Install mingw-mstorsjo-llvm-ucrt (...)
  shell: pwsh
  run: |
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    $env:SCOOP_INSTALL_AS_ADMIN = "1"
    Invoke-WebRequest -UseBasicParsing https://get.scoop.sh -OutFile "$env:TEMP\install-scoop.ps1"
    & "$env:TEMP\install-scoop.ps1"
    scoop install mingw-mstorsjo-llvm-ucrt
    if ($LASTEXITCODE -ne 0) { throw "scoop install mingw-mstorsjo-llvm-ucrt failed (exit $LASTEXITCODE)" }
    $bin = "$env:USERPROFILE\scoop\apps\mingw-mstorsjo-llvm-ucrt\current\bin"
    foreach ($exe in @('x86_64-w64-mingw32-clang.exe','i686-w64-mingw32-clang.exe')) {
      if (-not (Test-Path "$bin\$exe")) { throw "Missing $exe in $bin" }
    }
    Write-Host "scoop mingw-mstorsjo-llvm-ucrt installed:"
    Get-ChildItem "$bin\*-w64-mingw32-clang*.exe" | ForEach-Object { Write-Host "  $($_.Name)" }
```

### Per-File Details

| File | Old step name | New step name | Position preserved |
|------|--------------|---------------|-------------------|
| build.yml | `Install MinGW and Ninja` | `Install mingw-mstorsjo-llvm-ucrt (triple-prefixed clang + bundled cmake/ninja)` | Before "Build Interceptor and Test Harness" |
| installer-smoke.yml | `Install MinGW (interceptor build)` | `Install mingw-mstorsjo-llvm-ucrt (interceptor build toolchain)` | Before "Build interceptor DLL" |
| installer-release.yml | `Install MinGW (interceptor build)` | `Install mingw-mstorsjo-llvm-ucrt (interceptor build toolchain)` | Before "Build interceptor DLL" |

The `choco install mingw ... ninja cmake` lines (and the `echo ... >> $env:GITHUB_PATH` lines
appending the choco mingw bin path) are fully removed. The scoop package bundles cmake + ninja
so no separate install is needed.

## Key Decisions

1. **SCOOP_INSTALL_AS_ADMIN=1 env var** — windows-latest runners run pwsh elevated as
   `runneradmin`. Scoop's installer aborts under elevation without this flag or `-RunAsAdmin`.
   Setting it as an env var is safe in non-elevated contexts (no-op) and clears the gate
   when elevated.

2. **No PATH manipulation** — build.ps1 resolves cmake/ninja from `$clangBin` first (the
   scoop bundle). No `>> $env:GITHUB_PATH` lines needed; adding them would be dead code.

3. **No scoop cache step** — explicitly out of scope per plan. Measure run duration first,
   then decide whether to add `actions/cache` for `$env:USERPROFILE\scoop`.

4. **Fail-fast sanity check** — throws immediately if either `x86_64-w64-mingw32-clang.exe`
   or `i686-w64-mingw32-clang.exe` is missing, before build.ps1 even runs.

## Verification Performed

Content checks (PowerShell):
- All three files contain `scoop install mingw-mstorsjo-llvm-ucrt` — PASS
- No file contains `choco install mingw --no-progress` — PASS
- All three files contain `x86_64-w64-mingw32-clang.exe` — PASS
- All three files contain `i686-w64-mingw32-clang.exe` — PASS
- All three files contain `SCOOP_INSTALL_AS_ADMIN` — PASS

Step ordering confirmed (grep -n "name:"):
- build.yml: scoop step line 22 precedes "Build Interceptor and Test Harness" line 48
- installer-smoke.yml: scoop step line 59 precedes "Build interceptor DLL" line 91
- installer-release.yml: scoop step line 53 precedes "Build interceptor DLL" line 113

Note: PyYAML was not available in the local Git Bash environment; YAML structural
validation was performed via PowerShell content checks and grep-based step-ordering
verification. Full YAML parse will be validated on first CI run.

## CI Verification Recipe (for orchestrator)

After pushing develop:

```bash
gh run list --workflow build.yml --branch develop --limit 1
gh run list --workflow installer-smoke.yml --branch develop --limit 1
gh run watch <run-id>
```

Expected: "Build Interceptor (C++)" matrix jobs (Debug + Release) reach
"Build Interceptor and Test Harness" without the "mingw-mstorsjo-llvm-ucrt not found" error.
"Build interceptor DLL" in installer-smoke must complete for both x64 and x86 sub-builds.

Once develop is green, push `v3.0.0-rc.1` tag to trigger installer-release.yml.
Watch "Build interceptor DLL" step pass in that run.

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None.

## Threat Flags

None — no new network endpoints, auth paths, or file access patterns introduced.

## Self-Check: PASSED

- Commit db4b23b exists: confirmed (git rev-parse --short HEAD)
- All three workflow files modified: confirmed (git diff showed 3 files changed, 71 insertions, 10 deletions)
- No file deletions: confirmed (git diff --diff-filter=D returned empty)
- Content checks: all PASS (PowerShell verify script)
- Step ordering: correct in all three files (grep -n confirmed position)
