---
phase: quick-260429-cad
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - .github/workflows/build.yml
  - .github/workflows/installer-smoke.yml
  - .github/workflows/installer-release.yml
autonomous: true
requirements:
  - QUICK-260429-cad: "Standardize CI on scoop for NSIS installation (drop choco fallback) and fix stale build/ → build-x64/ paths in build.yml so post-toolchain workflows pass on windows-2025"

must_haves:
  truths:
    - "installer-smoke.yml installs NSIS via `scoop bucket add extras` + `scoop install nsis` in a dedicated step, then `Compile installer` runs makensis in a separate pwsh step that finds it on PATH"
    - "installer-release.yml installs NSIS via the SAME scoop step body, then compiles with the existing /DGOMAPI_VERSION=${{ steps.version.outputs.version }} arg in a separate pwsh step"
    - "Both installer workflows have ZERO references to `choco install nsis` (no try/catch fallback, no inline catch block)"
    - "build.yml references `build-x64/` (not `build/`) in all four post-build locations: Run Test Harness command, Run C++ Unit Tests working-directory, DLL artifact upload path, Test Harness artifact upload path"
    - "Workflow yaml remains syntactically valid (parses as YAML, no unrelated steps reordered or removed, matrix structure preserved)"
    - "The NSIS install step body is byte-for-byte identical between installer-smoke.yml and installer-release.yml (only the subsequent `Compile installer` step's makensis arg differs)"
  artifacts:
    - path: ".github/workflows/installer-smoke.yml"
      provides: "Smoke workflow installs NSIS via scoop extras bucket and compiles in a separate step"
      contains: "scoop bucket add extras"
    - path: ".github/workflows/installer-release.yml"
      provides: "Release workflow installs NSIS via scoop extras bucket and compiles in a separate step preserving the version ldflag"
      contains: "scoop bucket add extras"
    - path: ".github/workflows/build.yml"
      provides: "Build workflow references build-x64/ for test harness invocation, ctest working-directory, and artifact upload paths"
      contains: "build-x64/bin/go-mapi.dll"
  key_links:
    - from: ".github/workflows/installer-smoke.yml (Install NSIS step)"
      to: ".github/workflows/installer-smoke.yml (Compile installer step)"
      via: "scoop puts makensis on PATH for subsequent pwsh steps in the same job (scoop shim is added to user PATH at install time and GitHub runner pwsh sessions inherit it)"
      pattern: "scoop install nsis"
    - from: ".github/workflows/installer-release.yml (Install NSIS step)"
      to: ".github/workflows/installer-release.yml (Compile installer step)"
      via: "scoop puts makensis on PATH for subsequent pwsh steps; preserves /DGOMAPI_VERSION=${{ steps.version.outputs.version }}"
      pattern: "scoop install nsis"
    - from: ".github/workflows/build.yml (Build Interceptor and Test Harness step)"
      to: ".github/workflows/build.yml (Run Test Harness, Run C++ Unit Tests, Upload DLL Artifact, Upload Test Harness Artifact steps)"
      via: "build.ps1 writes outputs to build-$Arch (defaulting to build-x64 since no -Arch is passed); downstream steps must reference the same path"
      pattern: "build-x64/bin"
---

<objective>
Two pre-existing CI failures surfaced after the 260429-b4l toolchain fix landed:

1. **NSIS not on PATH on windows-2025** — `windows-latest` is now `windows-2025` which does NOT pre-install NSIS. The current `try { makensis /VERSION } catch { choco install nsis }` falls back to choco, but in installer-smoke.yml the install runs in a separate pwsh step from `Compile installer`, so the new PATH never propagates and `makensis` is "not recognized".
2. **Stale `build/` paths in build.yml** — `build.ps1` writes binaries to `build-$Arch` (e.g. `build-x64/bin/`), but four downstream steps in build.yml still reference `build/bin/` and `build/`, causing "directory name is invalid" failures in the C++ Unit Tests step.

This plan fixes both in a single commit. Standardize on scoop (already used by the same workflows for the mingw toolchain — extras bucket is the canonical scoop source for NSIS). Apply the mechanical `build/` → `build-x64/` rename in build.yml.

Purpose: Restore green CI on `develop` push so subsequent phase work isn't blocked by infrastructure failures.
Output: Three workflow files updated, one atomic commit, SUMMARY.md committed inside the worktree.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@./CLAUDE.md

<interfaces>
<!-- Current relevant slices of each file the executor will modify. -->
<!-- Use these directly — no codebase exploration needed. -->

From .github/workflows/installer-smoke.yml (lines 105-118 — the steps to REPLACE):
```yaml
      - name: Verify NSIS is available (pre-installed on windows-latest)
        shell: pwsh
        run: |
          try {
            $v = makensis /VERSION
            Write-Host "makensis version: $v"
          } catch {
            Write-Host "makensis not on PATH - installing via choco as fallback"
            choco install nsis --no-progress -y
          }

      - name: Compile installer
        shell: pwsh
        run: makensis /DGOMAPI_VERSION=0.0.0-smoke src\installer\go-mapi.nsi
```

From .github/workflows/installer-release.yml (lines 164-168 — the step to REPLACE):
```yaml
      - name: Verify NSIS + compile installer
        shell: pwsh
        run: |
          try { makensis /VERSION | Out-Null } catch { choco install nsis --no-progress -y }
          makensis /DGOMAPI_VERSION=${{ steps.version.outputs.version }} src\installer\go-mapi.nsi
```

From .github/workflows/build.yml (lines 52-73 — the four `build/` references to RENAME to `build-x64/`):
```yaml
      - name: Run Test Harness
        working-directory: src/interceptor
        run: .\build\bin\go-mapi-test-harness.exe .\build\bin\go-mapi.dll
        continue-on-error: true

      - name: Run C++ Unit Tests (doctest via ctest)
        working-directory: src/interceptor/build
        run: ctest --output-on-failure --build-config ${{ matrix.config }}

      - name: Upload DLL Artifact
        uses: actions/upload-artifact@v4
        with:
          name: go-mapi-dll-${{ matrix.config }}
          path: src/interceptor/build/bin/go-mapi.dll
          if-no-files-found: warn

      - name: Upload Test Harness Artifact
        uses: actions/upload-artifact@v4
        with:
          name: go-mapi-tests-${{ matrix.config }}
          path: src/interceptor/build/bin/go-mapi-test-harness.exe
          if-no-files-found: warn
```

From src/interceptor/build.ps1 (the param + buildDir contract — for context only, do NOT modify):
- `param([string]$Arch = "x64", ...)` — defaults to x64
- `$buildDir = Join-Path $interceptorRoot "build-$Arch"` — i.e. `build-x64/` when -Arch is omitted
- The build.yml step at line 50 calls `.\build.ps1 -Config ${{ matrix.config }} -Tests -Clean` — no `-Arch`, so it defaults to x64 → outputs land in `build-x64/`.
</interfaces>

<the_canonical_nsis_step_body>
<!-- Both installer workflows MUST use this EXACT step body for installing NSIS. -->
<!-- The only thing that differs between the two workflows is the subsequent -->
<!-- `Compile installer` step's /DGOMAPI_VERSION argument. -->

```yaml
      - name: Install NSIS via scoop (extras bucket)
        shell: pwsh
        run: |
          scoop bucket add extras
          scoop install nsis
          if ($LASTEXITCODE -ne 0) { throw "scoop install nsis failed (exit $LASTEXITCODE)" }
          makensis /VERSION
```

Followed by (installer-smoke.yml):
```yaml
      - name: Compile installer
        shell: pwsh
        run: makensis /DGOMAPI_VERSION=0.0.0-smoke src\installer\go-mapi.nsi
```

Followed by (installer-release.yml):
```yaml
      - name: Compile installer
        shell: pwsh
        run: makensis /DGOMAPI_VERSION=${{ steps.version.outputs.version }} src\installer\go-mapi.nsi
```

Note on `scoop bucket add extras`: idempotent — re-running is a no-op if the bucket is already added. NSIS lives in the `extras` bucket (https://github.com/ScoopInstaller/Extras), not the default bucket, so adding it is required for `scoop install nsis` to resolve.

Note on PATH propagation: scoop adds shims under `$env:USERPROFILE\scoop\shims` to user PATH at install time, and GitHub Actions pwsh sessions inherit user PATH between steps in the same job. This is why the install + compile can be split across two separate `run:` blocks (unlike choco, which requires `refreshenv` or a single `run: |` block).
</the_canonical_nsis_step_body>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Standardize CI on scoop for NSIS and fix build-x64/ paths</name>
  <files>.github/workflows/installer-smoke.yml, .github/workflows/installer-release.yml, .github/workflows/build.yml</files>
  <action>
Apply three mechanical edits across the three workflow files. Use the Edit tool — these are surgical replacements, not rewrites. Do NOT touch any unrelated step.

**Edit 1 — `.github/workflows/installer-smoke.yml` (lines 105-118):**

Replace the existing `Verify NSIS is available (pre-installed on windows-latest)` step AND keep the `Compile installer` step intact (only its preceding step changes). Concretely, replace lines 105-114 (the Verify NSIS step including its trailing blank line) with the canonical NSIS install step from `<the_canonical_nsis_step_body>` above. The existing `Compile installer` step at lines 116-118 stays as-is — it already has the right shell + run command for smoke (`/DGOMAPI_VERSION=0.0.0-smoke`).

After this edit, lines 105-118 read:
```yaml
      - name: Install NSIS via scoop (extras bucket)
        shell: pwsh
        run: |
          scoop bucket add extras
          scoop install nsis
          if ($LASTEXITCODE -ne 0) { throw "scoop install nsis failed (exit $LASTEXITCODE)" }
          makensis /VERSION

      - name: Compile installer
        shell: pwsh
        run: makensis /DGOMAPI_VERSION=0.0.0-smoke src\installer\go-mapi.nsi
```

**Edit 2 — `.github/workflows/installer-release.yml` (lines 164-168):**

Replace the single combined `Verify NSIS + compile installer` step with TWO separate steps: the canonical NSIS install step, then a dedicated `Compile installer` step that preserves the existing `/DGOMAPI_VERSION=${{ steps.version.outputs.version }}` argument.

After this edit, lines 164-... read:
```yaml
      - name: Install NSIS via scoop (extras bucket)
        shell: pwsh
        run: |
          scoop bucket add extras
          scoop install nsis
          if ($LASTEXITCODE -ne 0) { throw "scoop install nsis failed (exit $LASTEXITCODE)" }
          makensis /VERSION

      - name: Compile installer
        shell: pwsh
        run: makensis /DGOMAPI_VERSION=${{ steps.version.outputs.version }} src\installer\go-mapi.nsi
```

**Edit 3 — `.github/workflows/build.yml` (lines 53, 54, 58, 65, 72):**

Mechanical `build` → `build-x64` rename in four locations. The Edit tool can do this as four separate small Edits, OR one if the surrounding context is unique enough. Use four separate Edit calls to be safe — each `build/` token appears in a sufficiently distinct line.

Specifically:
- Line 54: `run: .\build\bin\go-mapi-test-harness.exe .\build\bin\go-mapi.dll` → `run: .\build-x64\bin\go-mapi-test-harness.exe .\build-x64\bin\go-mapi.dll`
- Line 58: `working-directory: src/interceptor/build` → `working-directory: src/interceptor/build-x64`
- Line 65: `path: src/interceptor/build/bin/go-mapi.dll` → `path: src/interceptor/build-x64/bin/go-mapi.dll`
- Line 72: `path: src/interceptor/build/bin/go-mapi-test-harness.exe` → `path: src/interceptor/build-x64/bin/go-mapi-test-harness.exe`

Step `name:` fields stay unchanged (`Run Test Harness`, `Run C++ Unit Tests (doctest via ctest)`, `Upload DLL Artifact`, `Upload Test Harness Artifact`).

**What NOT to touch:**
- The `Build Interceptor and Test Harness` step at line 48-50 (already correct — calls build.ps1 with default x64).
- Any other step in any workflow.
- The `Confirm installer artifact produced` step that follows `Compile installer` in installer-smoke.yml — it stays as-is.
- The `Replace staged binaries with signed versions` step in installer-release.yml (already references `build-x64/` and `build-x86/`).
- Any go-mapi.nsi content.
- actions/checkout version pins.

After applying all three edits, run a YAML sanity check on each modified file (Python's `yaml.safe_load` via the PowerShell tool, or just confirm the file still has the same top-level structure visually via Read). Do NOT push — verification is local only per the plan constraints.
  </action>
  <verify>
    <automated>powershell -NoProfile -Command "& { foreach ($f in @('.github/workflows/build.yml', '.github/workflows/installer-smoke.yml', '.github/workflows/installer-release.yml')) { python -c \"import yaml,sys; yaml.safe_load(open(sys.argv[1],encoding='utf-8')); print('OK', sys.argv[1])\" $f; if ($LASTEXITCODE -ne 0) { exit 1 } } ; if (Select-String -Path .github/workflows/installer-smoke.yml,.github/workflows/installer-release.yml -Pattern 'choco install nsis' -Quiet) { Write-Host 'FAIL: choco install nsis still present'; exit 1 } else { Write-Host 'OK: no choco install nsis references' } ; $stale = Select-String -Path .github/workflows/build.yml -Pattern 'src/interceptor/build/' ; if ($stale) { Write-Host 'FAIL: stale build/ paths still present in build.yml'; $stale; exit 1 } else { Write-Host 'OK: no stale build/ paths in build.yml' } ; $smoke = (Get-Content -Raw .github/workflows/installer-smoke.yml) ; $rel = (Get-Content -Raw .github/workflows/installer-release.yml) ; if ($smoke -notmatch 'scoop bucket add extras' -or $smoke -notmatch 'scoop install nsis') { Write-Host 'FAIL: smoke workflow missing scoop NSIS install'; exit 1 } ; if ($rel -notmatch 'scoop bucket add extras' -or $rel -notmatch 'scoop install nsis') { Write-Host 'FAIL: release workflow missing scoop NSIS install'; exit 1 } ; if ($rel -notmatch '/DGOMAPI_VERSION=\$\{\{ steps\.version\.outputs\.version \}\}') { Write-Host 'FAIL: release workflow lost version ldflag'; exit 1 } ; Write-Host 'ALL CHECKS PASSED' }"</automated>
  </verify>
  <done>All three workflow files parse as valid YAML, no `choco install nsis` references remain in either installer workflow, no `src/interceptor/build/` (stale) paths remain in build.yml, both installer workflows contain `scoop bucket add extras` + `scoop install nsis`, and installer-release.yml still has the `/DGOMAPI_VERSION=${{ steps.version.outputs.version }}` argument intact.</done>
</task>

<task type="auto">
  <name>Task 2: Write SUMMARY.md and commit (no push)</name>
  <files>.planning/quick/260429-cad-standardize-ci-on-scoop-scoop-install-ns/260429-cad-SUMMARY.md</files>
  <action>
Create the SUMMARY.md inside the worktree (this addresses the constraint that the previous quick task forgot it and the orchestrator had to backfill).

Use the standard summary template at `$HOME/.claude/get-shit-done/templates/summary.md`. Required sections:

- **Quick ID & description** — `260429-cad — Standardize CI on scoop (NSIS) and fix stale build/ paths in build.yml`
- **What changed** — bullet list of the three workflow file changes
- **Why** — Two pre-existing CI failures surfaced after 260429-b4l toolchain fix landed: (1) NSIS not pre-installed on windows-2025, choco fallback PATH didn't propagate to next pwsh step in installer-smoke; (2) build.ps1 outputs to `build-x64/` since QUICK-260423-ntu but build.yml still referenced `build/`.
- **Verification** — `powershell yaml.safe_load + grep checks all pass locally`. Note the workflow runs themselves cannot be verified without a push, which is intentionally out of scope per plan constraints.
- **Files modified** — the three workflow paths.
- **Follow-ups** — none. (Caching scoop installs, actions/checkout v5 bump, x86 build in build.yml, and the cosmetic `Restore cache failed` warning in installer-smoke are all explicitly out of scope per the task context.)

After writing the SUMMARY, stage it together with the three workflow changes and create ONE commit. Use a conventional-commits message:

```
ci: standardize on scoop for NSIS and fix stale build/ paths in build.yml

- installer-smoke.yml + installer-release.yml: replace choco fallback with
  `scoop bucket add extras` + `scoop install nsis`; split into separate
  Install + Compile steps so PATH propagates between pwsh sessions
- build.yml: rename build/ → build-x64/ in four locations to match
  build.ps1's per-arch output dir (introduced in QUICK-260423-ntu)

Closes the two CI failures that surfaced after 260429-b4l on windows-2025.
```

Use `rtk git add` for the four files explicitly (the three workflows + the SUMMARY) and `rtk git commit` with the message via heredoc. **Do NOT push.** Do NOT use `git add .` or `-A`.
  </action>
  <verify>
    <automated>powershell -NoProfile -Command "& { if (-not (Test-Path '.planning/quick/260429-cad-standardize-ci-on-scoop-scoop-install-ns/260429-cad-SUMMARY.md')) { Write-Host 'FAIL: SUMMARY.md missing'; exit 1 } ; $log = git log -1 --name-only --pretty=format:'%s' ; if ($log -notmatch 'ci: standardize on scoop' -and $log -notmatch 'ci\(') { Write-Host 'FAIL: latest commit subject does not match'; Write-Host $log; exit 1 } ; if ($log -notmatch '260429-cad-SUMMARY\.md') { Write-Host 'FAIL: SUMMARY.md not in latest commit'; Write-Host $log; exit 1 } ; foreach ($f in @('.github/workflows/build.yml', '.github/workflows/installer-smoke.yml', '.github/workflows/installer-release.yml')) { if ($log -notmatch [regex]::Escape($f)) { Write-Host \"FAIL: $f not in latest commit\"; Write-Host $log; exit 1 } } ; Write-Host 'OK: SUMMARY committed alongside workflow changes' }"</automated>
  </verify>
  <done>`260429-cad-SUMMARY.md` exists inside the worktree at the quick task directory and is included in the latest commit alongside all three modified workflow files. The commit subject starts with `ci:` (or `ci(` scoped) and the working tree is clean (`git status` shows no uncommitted changes related to this task). No `git push` was executed.</done>
</task>

</tasks>

<verification>
After both tasks complete:

```bash
rtk git log -1 --stat
rtk git status
```

Expected: clean working tree, latest commit touches exactly four files (three workflows + SUMMARY.md), commit subject is conventional-commits scoped to `ci`.

The actual CI run verification (workflows passing on windows-2025) requires a push, which is OUT OF SCOPE for this executor per the constraint `do NOT push from executor`. The user will push manually after reviewing the commit.
</verification>

<success_criteria>
- Three workflow files modified with the surgical edits described in Task 1
- YAML still parses for all three files
- No `choco install nsis` references remain in either installer workflow
- No stale `src/interceptor/build/` (without `-x64`) references remain in build.yml
- The NSIS install step body is byte-for-byte identical between installer-smoke.yml and installer-release.yml
- installer-release.yml's `Compile installer` step still passes `/DGOMAPI_VERSION=${{ steps.version.outputs.version }}`
- SUMMARY.md exists at `.planning/quick/260429-cad-standardize-ci-on-scoop-scoop-install-ns/260429-cad-SUMMARY.md` and is committed in the same commit as the workflow changes
- Working tree is clean after Task 2
- No `git push` was executed
</success_criteria>

<output>
The SUMMARY.md is created as part of Task 2 (per the constraint requiring it be committed inside the worktree before exit). No additional output artifacts.
</output>
