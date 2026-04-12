---
phase: 05-release-cut
plan: 02
subsystem: testing
tags: [windows-sandbox, inno-setup, powershell, rel-02, local-repro]

# Dependency graph
requires:
  - phase: 03-inno-setup-installer-signing-distribution
    provides: src/installer/go-mapi.iss compiled to go-mapi-setup.exe + [Registry]/[Files] sections that install-and-verify.ps1 asserts against
provides:
  - Committed sandbox.wsb declarative Windows Sandbox config
  - install-and-verify.ps1 in-sandbox runner (silent install -> 6 HKLM keys -> 4 files -> silent uninstall -> clean-state)
  - Hardened run-sandbox-test.ps1 -FullTest branch (replaces WinAppDriver TODO stub)
  - tests/sandbox/README.md documenting prerequisites, entry points, runtime, failure modes
affects: [05-04 (release + UAT — sandbox harness is fallback UAT env for REL-06), future installer edits (local repro path when CI surfaces flakes)]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Windows Sandbox .wsb declarative config for REL-02 local repro"
    - "In-sandbox SYSTEM-context runner script writing logs to C:\\output writable share"
    - "Host-side installer presence check before launching sandbox (fail fast + compile hint)"

key-files:
  created:
    - tests/sandbox/sandbox.wsb
    - tests/sandbox/install-and-verify.ps1
    - tests/sandbox/README.md
  modified:
    - tests/sandbox/run-sandbox-test.ps1

key-decisions:
  - "Hardcode HostFolder to C:\\dev\\go-mapi in sandbox.wsb (marcwin convention); README instructs non-marcwin clones to edit the line — .wsb does not expand env vars"
  - "Do NOT run Pester installer.Tests.ps1 inside sandbox — keep sandbox ~5 min vs Pester's ~15 min; Pester stays authoritative CI gate via installer-smoke.yml"
  - "Host-side installer existence check BEFORE sandbox launch in -FullTest branch (fail fast with iscc.exe compile hint rather than starting a sandbox just to error out)"

patterns-established:
  - "Sandbox harness vs CI separation: tests/sandbox = fast local feedback loop (~5 min, sandbox), src/installer/tests/installer.Tests.ps1 = authoritative ship gate (~15 min, CI)"
  - "In-sandbox scripts log to C:\\output\\*.log via a writable share that run-sandbox-test.ps1 creates at $env:TEMP\\go-mapi-sandbox-output"

requirements-completed: [REL-02]

# Metrics
duration: 3min
completed: 2026-04-11
---

# Phase 5 Plan 2: Sandbox Harness Hardening Summary

**Windows Sandbox harness hardened from DLL-registration-only into a full v2.0.0 installer silent-install -> 6 HKLM registry keys -> 4 installed files -> silent uninstall -> clean-state repro loop, with declarative .wsb config and README for Marc's local repro path (REL-02).**

## Performance

- **Duration:** 3 min
- **Started:** 2026-04-11T07:55:35Z
- **Completed:** 2026-04-11T07:58:49Z
- **Tasks:** 2
- **Files modified:** 4 (3 created, 1 edited)

## Accomplishments

- Declarative `sandbox.wsb` committed so Marc can launch a baseline sandbox via double-click or `wsb start --config`, with `<ReadOnly>true</ReadOnly>` pinned on the project share to prevent guest-side contamination of the host source tree (T-05-02-05 mitigation)
- `install-and-verify.ps1` replaces the WinAppDriver TODO stub with a concrete 6-step runner (installer presence, silent install, 6 HKLM registry keys, 4 installed files, silent uninstall via `unins000.exe`, clean-state post-uninstall verification)
- `run-sandbox-test.ps1 -FullTest` now fails fast BEFORE launching a sandbox if `src/installer/dist/go-mapi-setup.exe` is missing on the host, with a compile-command hint pointing Marc at `iscc.exe /DGOMAPIVersion=2.0.0-local src\installer\go-mapi.iss`
- `tests/sandbox/README.md` documents Windows 11 24H2+ `wsb` CLI prerequisite, the `-RegistrationOnly` fast path and `-FullTest` full path, expected runtime table (~3-5 min for -FullTest, up to 10 min on cold machines), failure modes cross-referenced to the exact log files, and the intentional separation from the authoritative CI `installer-smoke.yml` Pester test

## Task Commits

1. **Task 1: Create sandbox.wsb + install-and-verify.ps1** — `549c120` (test)
2. **Task 2: Harden run-sandbox-test.ps1 -FullTest branch + write tests/sandbox/README.md** — `fcdb045` (docs)

## Files Created/Modified

- `tests/sandbox/sandbox.wsb` (created) — Declarative Windows Sandbox config: 8 GB memory, Default networking, VGpu/Audio/Video/Printer/Clipboard disabled, `<ProtectedClient>Enable</ProtectedClient>`, single read-only MappedFolder `C:\dev\go-mapi` -> `C:\go-mapi`. No `<LogonCommand>` — runner is invoked on demand via `wsb exec` by `run-sandbox-test.ps1`.
- `tests/sandbox/install-and-verify.ps1` (created) — In-sandbox runner (SYSTEM context). 6 steps: installer presence check, silent install with `/VERYSILENT /SUPPRESSMSGBOXES /LOG=C:\output\inno-install.log`, 6 HKLM registry key assertions (`Clients\Mail\go-mapi` + `Google\Chrome`, `Microsoft\Edge`, `Chromium`, `BraveSoftware\Brave-Browser`, `Vivaldi` NativeMessagingHosts), 4 file assertions (`%ProgramFiles%\go-mapi\go-mapi.dll`, `go-mapi-host.exe`, `%ProgramData%\go-mapi\com.gomapi.host.json`, `uninst\previous-mail-client.json`), silent uninstall via `unins000.exe`, clean-state post-uninstall verification. Writes `C:\output\install-and-verify.log` (retrieved by host).
- `tests/sandbox/run-sandbox-test.ps1` (modified) — Replaced the TODO stub `Write-Host "TODO: Implement WinAppDriver-based UI automation"` with a concrete -FullTest branch: host-side installer presence check, `Invoke-SandboxCommand` dispatching `install-and-verify.ps1` via `powershell -ExecutionPolicy Bypass -File C:\go-mapi\tests\sandbox\install-and-verify.ps1`, log retrieval from `$OutputFolder\install-and-verify.log`, colored exit banners (`REL-02 FULL TEST PASSED` / `FAILED`). No other lines of the file changed — preserves the existing `wsb start --raw` dynamic-share flow, `Invoke-SandboxCommand` helper, `-SetupOnly`, `-RegistrationOnly`, `-KeepRunning` switches.
- `tests/sandbox/README.md` (created) — 130-line doc covering prerequisites (Windows 11 24H2+, `wsb` CLI, Windows Sandbox feature, PowerShell 7+, Inno Setup 6), the two entry points (`-RegistrationOnly` ~1 min and `-FullTest` ~5 min), host-side compile sequence for v2.0.0-local builds, expected-runtime table, failure modes with log-file pointers, relation-to-other-test-surfaces comparison table, and the files-in-this-directory index.

## Decisions Made

- **Hardcode `<HostFolder>C:\dev\go-mapi</HostFolder>` in sandbox.wsb**: The .wsb XML schema does not expand environment variables at launch time, and the committed config has to be a concrete path. Chose marcwin convention (`~/.claude/CLAUDE.md` "Windows (marcwin): C:\dev\\"); README.md instructs non-marcwin clones to edit the line. The `run-sandbox-test.ps1` orchestrator does NOT use the .wsb file directly — it dynamically shares `$PSScriptRoot | Split-Path | Split-Path`, so only the "double-click the .wsb" workflow is affected by clone-location drift.
- **Intentional separation from Pester authoritative test**: Did NOT wire `src/installer/tests/installer.Tests.ps1` into the sandbox. Kept the sandbox runner lightweight at ~5 min (vs Pester's ~15 min) so Marc has a fast local feedback loop when iterating on installer changes. Pester remains the authoritative ship gate via `installer-smoke.yml` on `windows-latest`. The `tests/sandbox/README.md` "Relation to other test surfaces" table makes this split explicit.
- **Host-side installer check BEFORE sandbox launch in -FullTest**: Fail fast with the exact `iscc.exe` compile command rather than starting a sandbox just to error out 30 seconds in. Saves the ~30-60s sandbox cold-start time on every iteration where Marc forgets to recompile the installer after a source change.

## Deviations from Plan

None - plan executed exactly as written. No auto-fixes needed; task actions and acceptance criteria matched the code landed.

## Issues Encountered

- **Initial worktree base mismatch**: `git merge-base HEAD 5ef76da5` returned `8a01fa31` (a v1.0.0 tag commit, not a descendant of the Phase 5 scaffolding commit). Resolved per the `<worktree_branch_check>` instructions with `git reset --hard 5ef76da5a1899b08e97b581684f65838371b9c60` before starting any plan work. Confirmed after reset: `git log --oneline -1 HEAD` = `5ef76da docs(05): scaffold Phase 5 Release Cut — reopen v2.0.0 until shipped`. No content loss (the v1.0.0 state was never in scope for this worktree).
- **Parallel agent commits on shared worktree dir**: Another wave-1 agent (05-01) committed between my two tasks, so `git log --oneline 5ef76da5..HEAD` shows interleaved commits (`8adb63f`, `a4e128c`, `15f8d1b` from 05-01 alongside `549c120`, `fcdb045` from 05-02). Expected for `--no-verify` parallel execution per the `<parallel_execution>` contract. My task commits are isolated to `tests/sandbox/*`, no file-level collision with 05-01's scope (`src/interceptor/json_writer.h`, `.github/workflows/*`, `.planning/phases/05-release-cut/05-MANUAL-STEPS.md`).

## Runtime Verification Status

**Not performed in this worktree.** Plan explicitly notes (per the orchestrator prompt `<plan_note>`): "You CANNOT test the sandbox run from inside this worktree (Windows Sandbox requires marcwin)". All static verification passed:

- `sandbox.wsb` contains `<HostFolder>`, `<SandboxFolder>C:\go-mapi</SandboxFolder>`, `<ReadOnly>true</ReadOnly>` — checked via Grep
- `install-and-verify.ps1` contains 6 HKLM keys, `VERYSILENT` (3 occurrences: install, uninstall, uninst check), `unins000.exe`, `go-mapi-setup.exe` — checked via Grep
- `run-sandbox-test.ps1` TODO stub removed, `install-and-verify.ps1` invocation present, `REL-02 FULL TEST PASSED` banner present — checked via Grep
- PowerShell 7.x `[System.Management.Automation.Language.Parser]::ParseFile` on both `install-and-verify.ps1` and `run-sandbox-test.ps1` returned zero errors
- README.md contains "Windows 11 24H2", `pwsh tests\sandbox\run-sandbox-test.ps1 -FullTest` exact entry point, `install-and-verify.ps1` references — checked via Grep

Marc's manual verification side (marcwin, Windows 11 24H2+) runs: `iscc.exe /DGOMAPIVersion=2.0.0-local src\installer\go-mapi.iss` then `pwsh tests\sandbox\run-sandbox-test.ps1 -FullTest`. Expected green banner: `=== REL-02 FULL TEST PASSED ===`.

## User Setup Required

None - no external service configuration. The sandbox harness itself requires Windows 11 24H2+ with the Windows Sandbox feature enabled (documented in README.md prerequisites), but this is Marc's one-time local dev setup, not an app config step.

## Next Phase Readiness

- REL-02 closed at the source level. When Marc next runs `pwsh tests\sandbox\run-sandbox-test.ps1 -FullTest` on marcwin after compiling the installer, the harness will either print `REL-02 FULL TEST PASSED` (closing REL-02 at runtime) or surface a specific failing assertion with a log-file pointer.
- Sandbox harness is now the fallback UAT environment for REL-06 (plan 05-04), per D-03. If marcwin UAT encounters issues, the same sandbox flow provides a second-opinion repro environment without touching host state.
- No blockers introduced. No dependencies on unmerged work.

## Self-Check: PASSED

- FOUND: tests/sandbox/sandbox.wsb
- FOUND: tests/sandbox/install-and-verify.ps1
- FOUND: tests/sandbox/run-sandbox-test.ps1 (modified, TODO stub removed)
- FOUND: tests/sandbox/README.md
- FOUND: commit 549c120 (Task 1: test(05-02): add sandbox.wsb + install-and-verify.ps1)
- FOUND: commit fcdb045 (Task 2: docs(05-02): harden tests/sandbox harness + README)

---
*Phase: 05-release-cut*
*Completed: 2026-04-11*
