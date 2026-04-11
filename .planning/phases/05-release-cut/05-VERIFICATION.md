---
phase: 05-release-cut
verified: 2026-04-11T08:30:00Z
status: human_needed
score: 7/7 source-side must-haves verified; 4 runtime gates require Marc's authenticated Windows environment
overrides_applied: 0
human_verification:
  - test: "REL-01 — Trigger the three windows-latest CI workflows on develop"
    expected: "gh run list --workflow=installer-smoke.yml --limit=1 --json conclusion -> \"success\"; same for e2e.yml and go-race-nightly.yml"
    why_human: "Executor sandbox has no authenticated gh CLI (per D-02). Marc runs the commands in 05-MANUAL-STEPS.md §REL-01 from an authenticated terminal on marcwin."
    commands: |
      gh workflow run installer-smoke.yml --ref develop
      gh workflow run e2e.yml --ref develop
      gh workflow run go-race-nightly.yml --ref develop
      # Then for each, watch and confirm conclusion=success:
      gh run list --workflow=installer-smoke.yml --limit=1 --json conclusion
      gh run list --workflow=e2e.yml --limit=1 --json conclusion
      gh run list --workflow=go-race-nightly.yml --limit=1 --json conclusion
  - test: "REL-02 runtime — Run the hardened Windows Sandbox harness end-to-end"
    expected: "tests/sandbox/run-sandbox-test.ps1 -FullTest prints '=== REL-02 FULL TEST PASSED ===' after install-and-verify.ps1 asserts 6 HKLM keys, 4 installed files, silent uninstall, and clean post-uninstall state"
    why_human: "Requires Windows 11 24H2+ with Windows Sandbox feature enabled and a pre-compiled src/installer/dist/go-mapi-setup.exe on the host. Source-side of REL-02 is fully verified; runtime gate is Marc-local-only."
    commands: |
      # On marcwin, from repo root:
      cd src\interceptor && .\build.ps1 -Config Release -Clean ; cd ..\..
      cd src\native-host && go build -ldflags "-s -w -X main.Version=2.0.0-local" -o build\go-mapi-host.exe . ; cd ..\..
      & "C:\Program Files (x86)\Inno Setup 6\iscc.exe" /DGOMAPIVersion=2.0.0-local src\installer\go-mapi.iss
      pwsh tests\sandbox\run-sandbox-test.ps1 -FullTest
  - test: "REL-05 — Push v2.0.0 tag and verify release publication"
    expected: "installer-release.yml reaches conclusion:success; curl -IL https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe returns HTTP 200 with non-empty Content-Length; gh release view v2.0.0 shows go-mapi-setup.exe attached"
    why_human: "Tag push requires explicit approval and authenticated remote. D-02 Marc-owned step. Runbook documented in 05-MANUAL-STEPS.md §REL-05."
    commands: |
      git checkout develop && git pull --ff-only origin develop && git status
      git tag -a v2.0.0 -m "go-mapi v2.0.0 — first shipped milestone (unsigned fallback per D-01)"
      git push origin v2.0.0
      gh run watch $(gh run list --workflow=installer-release.yml --limit=1 --json databaseId --jq '.[0].databaseId')
      curl -IL https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe
      gh release view v2.0.0
  - test: "REL-06 — Manual end-to-end UAT on a real Windows box"
    expected: "All 10 UAT steps in 05-UAT.md pass on marcwin (or Windows Sandbox). The shipping gate (Step 9) is: a Gmail draft successfully appears in the target Gmail account after a 'Send to Mail recipient' action from a Win32 app."
    why_human: "Requires a real Windows desktop with Chrome signed into a Gmail account, SmartScreen click-through, UAC acceptance, and visual observation of the MISSING -> READY transition + one-time success toast. No way to automate in the executor sandbox."
    commands: |
      # 1. Open .planning/phases/05-release-cut/05-UAT.md in the editor
      # 2. Follow Steps 1-10 on marcwin, filling in the bracketed fields as you go
      # 3. Mark the three-way disposition (PASSED / PASSED-WITH-NOTES / FAILED)
      # 4. Commit the filled 05-UAT.md to develop before running REL-07:
      git add .planning/phases/05-release-cut/05-UAT.md
      git commit -m "docs(05-06): record v2.0.0 UAT session (REL-06)"
  - test: "REL-07 — Re-archive the v2.0.0 milestone"
    expected: ".planning/STATE.md contains 'milestone_complete'; .planning/MILESTONES.md has a v2.0.0 entry; Phase 1-5 directories moved under .planning/milestones/v2.0.0-phases/; archival commit on develop; v2.0.0 tag still exists"
    why_human: "Marc-invoked GSD command. Runs after REL-05 + REL-06 close. Must run against runtime-verified state, not the previous autonomous-run archive (rolled back per D-07)."
    commands: |
      /gsd:complete-milestone v2.0.0
      grep -q "milestone_complete" .planning/STATE.md
      test -f .planning/MILESTONES.md && grep -q "^## v2.0.0" .planning/MILESTONES.md
      test -d .planning/milestones/v2.0.0-phases || test -d .planning/milestones/v2.0.0
---

# Phase 5: Release Cut Verification Report

**Phase Goal:** A real user can download `go-mapi-setup.exe` from the v2.0.0 GitHub Releases page, install it on a fresh Windows box, and successfully create a Gmail draft via a "Send to Mail recipient" action. Source-complete → actually shipped.

**Verified:** 2026-04-11T08:30:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

---

## Goal Achievement

Phase 5 is a documentation-forward release cut. Per decision D-02 in `05-CONTEXT.md`, most REL-* requirements are intentionally Marc-owned manual steps because they require authenticated `gh` CLI, a real Windows machine with Admin + Chrome + Gmail, or explicit approval for tag push. The executor's deliverables are (a) one source fix (REL-04), (b) a hardened Windows Sandbox harness at the source level (REL-02), (c) the end-user-focused README rewrite (REL-03), and (d) a complete runbook + UAT checklist covering REL-01/REL-05/REL-06/REL-07.

**Source-side verification: all 7 must-haves from the 4 plan frontmatters are verified in the codebase.** The runtime gates (REL-01 CI triggers, REL-02 harness runtime, REL-05 tag push, REL-06 UAT session, REL-07 milestone re-archive) require Marc's authenticated Windows environment and are listed under `human_verification` with exact copy-paste commands.

### Observable Truths

| #   | Truth                                                                                                                                               | Status                | Evidence                                                                                                                                                              |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | json_writer.h:36 no longer emits `-Wcomment` under GCC/MinGW (REL-04)                                                                               | ✓ VERIFIED            | Line 36 reads `// Write a MailMessage to a JSON file in %TEMP%/go-mapi/` (forward slashes). No trailing `\` in any `//` comment (`grep -nE 'go-mapi\\$'` returns 0).  |
| 2   | Marc has a documented `gh workflow run` command sequence for installer-smoke + e2e + go-race-nightly on develop (REL-01 runbook)                   | ✓ VERIFIED            | `05-MANUAL-STEPS.md` lines 15-87 contain `## REL-01:` with all three `gh workflow run` commands, `gh run watch` patterns, sign-off checklist, and flake watch list.  |
| 3   | Committed `.wsb` Windows Sandbox config exists (REL-02 source)                                                                                     | ✓ VERIFIED            | `tests/sandbox/sandbox.wsb` (17 lines) with `<HostFolder>C:\dev\go-mapi</HostFolder>`, `<SandboxFolder>C:\go-mapi</SandboxFolder>`, `<ReadOnly>true</ReadOnly>`.      |
| 4   | `run-sandbox-test.ps1 -FullTest` runs the full install → verify → uninstall flow via `install-and-verify.ps1` (REL-02 source)                      | ✓ VERIFIED            | TODO stub removed; `run-sandbox-test.ps1:194` invokes `install-and-verify.ps1` via `powershell -ExecutionPolicy Bypass -File C:\go-mapi\tests\sandbox\...`.          |
| 5   | `tests/sandbox/README.md` documents Windows 11 24H2+, entry points, expected runtime (REL-02 docs)                                                 | ✓ VERIFIED            | 133 lines; contains "Windows 11 24H2", `-FullTest`, `-RegistrationOnly`, `install-and-verify.ps1` references.                                                        |
| 6   | README.md presents a three-step install flow pointing at GitHub Releases, with SmartScreen walkthrough matching `.github/release-template.md` (REL-03) | ✓ VERIFIED            | README.md has `## Installation` (line 68), `## Usage` (117), `## Uninstall` (132), `## Privacy` (143), `## Development` (164); exact URL `releases/latest/download/go-mapi-setup.exe` matches `InstallPrompt.tsx:5`; "More info" + "Run anyway" present; no `## Quick Start`; no `irm https`. |
| 7   | `05-UAT.md` template exists with the full end-to-end checklist Marc fills during REL-06                                                            | ✓ VERIFIED            | 172 lines, 10 UAT steps (Download → SmartScreen → UAC → FS state → registry state → extension load → MISSING→READY → MAPI trigger → Gmail draft → uninstall), 50 `[ ]` checkboxes, three-way Ship/Block disposition. |
| 8   | Marc has a documented `git tag v2.0.0 + git push + curl -IL + gh release view` sequence for REL-05                                                 | ✓ VERIFIED (docs)     | `05-MANUAL-STEPS.md` §REL-05 (line 89+) contains `git tag -a v2.0.0`, `git push origin v2.0.0`, `gh run watch` on installer-release.yml, `curl -IL` on the stable URL, and 6-item sign-off checklist. |
| 9   | Marc has a documented `/gsd:complete-milestone v2.0.0` invocation with post-condition verification for REL-07                                       | ✓ VERIFIED (docs)     | `05-MANUAL-STEPS.md` §REL-07 (line 221+) contains the command, 5 documented effects, 4-command verification block, 6-item sign-off checklist, idempotency + rollback guidance. |
| 10  | REL-01 CI workflows run green at least once on develop (RUNTIME)                                                                                   | ? UNCERTAIN (human)   | Requires Marc's authenticated gh CLI. See `human_verification[0]`.                                                                                                    |
| 11  | REL-02 `-FullTest` harness actually passes on Windows 11 24H2+ (RUNTIME)                                                                            | ? UNCERTAIN (human)   | Source-side complete; runtime requires marcwin. See `human_verification[1]`.                                                                                          |
| 12  | REL-05 tag push succeeds, installer-release.yml publishes, stable URL returns 200 (RUNTIME)                                                        | ? UNCERTAIN (human)   | Requires git push approval + network verification. See `human_verification[2]`.                                                                                      |
| 13  | REL-06 UAT session passes on a real Windows box with Gmail draft created end-to-end (RUNTIME — shipping gate)                                      | ? UNCERTAIN (human)   | Requires marcwin + Chrome + Gmail. See `human_verification[3]`.                                                                                                       |
| 14  | REL-07 milestone re-archived against runtime-verified state (RUNTIME)                                                                              | ? UNCERTAIN (human)   | Requires REL-05 + REL-06 to have closed first. See `human_verification[4]`.                                                                                           |

**Source-side score:** 9/9 truths verified in code/docs.
**Runtime score:** 0/5 runtime gates can be verified from the executor sandbox — all 5 routed to `human_verification`.
**Overall:** status=`human_needed` — automated verification is clean; Marc now runs the documented manual sequence.

### Required Artifacts

| Artifact                                                           | Expected                                                         | Status     | Details                                                                                                                                        |
| ------------------------------------------------------------------ | ---------------------------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/interceptor/json_writer.h`                                    | Warning-free line-36 comment with `%TEMP%/go-mapi/`              | ✓ VERIFIED | Line 36 contains `%TEMP%/go-mapi/`. No `go-mapi\` trailing backslash anywhere in the file.                                                     |
| `.planning/phases/05-release-cut/05-MANUAL-STEPS.md`               | Executable runbook with REL-01/05/06/07 sections                 | ✓ VERIFIED | 273 lines. Contains `## REL-01`, `## REL-05`, `## REL-06`, `## REL-07`. 0 `Filled in by Plan 04` placeholders remain. 19 key-command matches.  |
| `tests/sandbox/sandbox.wsb`                                        | Declarative Windows Sandbox config with shared folders           | ✓ VERIFIED | 17 lines. `<HostFolder>C:\dev\go-mapi</HostFolder>`, `<SandboxFolder>C:\go-mapi</SandboxFolder>`, `<ReadOnly>true</ReadOnly>`.                 |
| `tests/sandbox/install-and-verify.ps1`                             | In-sandbox runner asserting 6 HKLM keys + 4 files + clean state  | ✓ VERIFIED | 123 lines. 6 HKLM registry assertions (Clients\Mail + 5 browser NativeMessagingHosts), silent install with `/VERYSILENT`, `unins000.exe` uninstall, clean-state verification. |
| `tests/sandbox/run-sandbox-test.ps1`                               | `-FullTest` branch invokes `install-and-verify.ps1`              | ✓ VERIFIED | TODO stub replaced (line 145 area). `install-and-verify.ps1` invoked at line 194. `REL-02 FULL TEST PASSED/FAILED` banners at lines 208/212.   |
| `tests/sandbox/README.md`                                          | Prerequisites + entry points + runtime + failure modes           | ✓ VERIFIED | 133 lines. Documents Windows 11 24H2+, `wsb` CLI, `-FullTest` / `-RegistrationOnly`, expected runtime table, failure modes with log pointers.  |
| `README.md`                                                        | End-user install flow + SmartScreen walkthrough + Dev section    | ✓ VERIFIED | 264 lines. All required headings present; exact download URL present; SmartScreen 3-step walkthrough matches release-template; no legacy `irm https` remains. |
| `.planning/phases/05-release-cut/05-UAT.md`                        | Fill-in-the-blank UAT checklist template                         | ✓ VERIFIED | 172 lines. 10 steps, 50 `[ ]` checkboxes, filesystem + registry probes, Ship/Block disposition.                                                |

### Key Link Verification

| From                                             | To                                                                                          | Via                                   | Status     | Details                                                                                                      |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------- | ------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------ |
| `05-MANUAL-STEPS.md` REL-01                      | `.github/workflows/installer-smoke.yml`                                                     | `gh workflow run installer-smoke.yml` | ✓ WIRED    | Exact literal command present at line 24.                                                                    |
| `05-MANUAL-STEPS.md` REL-01                      | `.github/workflows/e2e.yml`                                                                 | `gh workflow run e2e.yml`             | ✓ WIRED    | Exact literal command present.                                                                                |
| `05-MANUAL-STEPS.md` REL-01                      | `.github/workflows/go-race-nightly.yml`                                                     | `gh workflow run go-race-nightly.yml` | ✓ WIRED    | Exact literal command present.                                                                                |
| `run-sandbox-test.ps1 -FullTest`                 | `install-and-verify.ps1`                                                                    | `wsb exec` of in-sandbox runner       | ✓ WIRED    | `run-sandbox-test.ps1:194` invokes `install-and-verify.ps1` by absolute path inside sandbox.                 |
| `install-and-verify.ps1`                         | `src/installer/dist/go-mapi-setup.exe`                                                      | `Start-Process /VERYSILENT`           | ✓ WIRED    | Installer path declared (line 7-ish), Start-Process with /VERYSILENT /SUPPRESSMSGBOXES present.              |
| `README.md Installation` section                 | `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`          | Markdown direct link                  | ✓ WIRED    | Exact URL byte-identical with `src/extension/src/popup/InstallPrompt.tsx:5` `INSTALLER_DOWNLOAD_URL`.        |
| `README.md SmartScreen` subsection               | `.github/release-template.md`                                                               | Shared 3-step walkthrough phrasing    | ✓ WIRED    | "More info" + "Run anyway" + UAC sequence present verbatim in README lines 108-110.                         |
| `05-MANUAL-STEPS.md` REL-05                      | `git tag v2.0.0 + git push origin v2.0.0`                                                   | explicit command block                | ✓ WIRED    | Both commands present in §REL-05.                                                                             |
| `05-MANUAL-STEPS.md` REL-05                      | `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`          | `curl -IL` verification               | ✓ WIRED    | `curl -IL https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` present.         |
| `05-MANUAL-STEPS.md` REL-06                      | `05-UAT.md`                                                                                 | link to the checklist template        | ✓ WIRED    | `05-UAT.md` reference present in §REL-06.                                                                    |
| `05-MANUAL-STEPS.md` REL-07                      | `/gsd:complete-milestone v2.0.0`                                                            | documented GSD command invocation     | ✓ WIRED    | Exact string `/gsd:complete-milestone v2.0.0` present in §REL-07.                                            |

### Requirements Coverage

| Requirement | Source Plan        | Description                                                                 | Status        | Evidence                                                                                                     |
| ----------- | ------------------ | --------------------------------------------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------ |
| REL-01      | 05-01              | Three windows-latest CI workflows run green at least once on develop         | ? NEEDS HUMAN | Runbook documented in `05-MANUAL-STEPS.md §REL-01`. Runtime gate routed to `human_verification[0]`.          |
| REL-02      | 05-02              | `tests/sandbox/` hardened to run full v2.0.0 install → E2E → uninstall flow  | ✓ SATISFIED (source) / ? NEEDS HUMAN (runtime) | All source artifacts landed and parsed clean; runtime assertion routed to `human_verification[1]`.           |
| REL-03      | 05-03              | README.md rewritten for real v2.0.0 distribution flow                        | ✓ SATISFIED   | README 264 lines, all required sections, exact URL, SmartScreen walkthrough, Dev section, legacy flow removed. |
| REL-04      | 05-01              | PHASE-4-FINDING-02 closed (json_writer.h:36 -Wcomment)                       | ✓ SATISFIED   | Line 36 reads `%TEMP%/go-mapi/`, no trailing backslash, one-line source fix.                                 |
| REL-05      | 05-04              | v2.0.0 tag pushed, installer-release.yml green, stable URL 200               | ? NEEDS HUMAN | Runbook documented in `05-MANUAL-STEPS.md §REL-05`. Runtime gate routed to `human_verification[2]`.          |
| REL-06      | 05-04              | Manual end-to-end UAT passes on real Windows box                             | ? NEEDS HUMAN | Template in `05-UAT.md`, procedural summary in `05-MANUAL-STEPS.md §REL-06`. Runtime gate routed to `human_verification[3]`. |
| REL-07      | 05-04              | `/gsd:complete-milestone v2.0.0` re-run against runtime-verified state       | ? NEEDS HUMAN | Runbook documented in `05-MANUAL-STEPS.md §REL-07`. Runtime gate routed to `human_verification[4]`.          |

All 7 REL-* requirements are accounted for — either SATISFIED in code (REL-03, REL-04), SATISFIED at source level with runtime-gate-human (REL-02), or NEEDS HUMAN with an exact copy-paste command sequence in `05-MANUAL-STEPS.md` (REL-01, REL-05, REL-06, REL-07). No orphaned REL-* IDs. This matches the phase prompt's explicit note that runtime gates can only be executed on Marc's authenticated Windows environment.

### Anti-Patterns Found

None. Scans for TODO/FIXME/placeholder markers on modified files:

| File                                                | Anti-pattern search                                 | Result     |
| --------------------------------------------------- | --------------------------------------------------- | ---------- |
| `src/interceptor/json_writer.h`                     | `go-mapi\` trailing backslash in `//` comment       | 0 matches  |
| `.planning/phases/05-release-cut/05-MANUAL-STEPS.md` | `Filled in by Plan 04` placeholder                  | 0 matches  |
| `tests/sandbox/run-sandbox-test.ps1`                | `TODO: Implement WinAppDriver` stub                 | 0 matches  |
| `README.md`                                         | `## Quick Start` legacy section                     | 0 matches  |
| `README.md`                                         | `irm https` legacy one-liner install                | 0 matches  |

All four plans' SUMMARY self-checks passed and no anti-patterns were introduced. The "intentional Marc-owned" manual items are NOT stubs — they are documentation deliverables per D-02 and represent the correct executor output for a release-cut phase.

### Behavioral Spot-Checks

| Behavior                                                           | Command                                                                                                | Result                 | Status     |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ | ---------------------- | ---------- |
| json_writer.h comment warning-free                                 | `grep -nE 'go-mapi\\$' src/interceptor/json_writer.h`                                                  | 0 matches              | ✓ PASS     |
| json_writer.h line 36 uses forward-slash path                      | `grep -n '%TEMP%/go-mapi/' src/interceptor/json_writer.h`                                              | line 36 match          | ✓ PASS     |
| MANUAL-STEPS has all 4 REL section headings                        | `grep -E '^## REL-(01\|05\|06\|07)' 05-MANUAL-STEPS.md`                                                | 4 matches              | ✓ PASS     |
| install-and-verify.ps1 has all 6 HKLM registry keys                | `grep 'HKLM:\\SOFTWARE' tests/sandbox/install-and-verify.ps1`                                          | 6 matches              | ✓ PASS     |
| README download URL byte-identical with InstallPrompt.tsx          | cross-grep                                                                                              | match                  | ✓ PASS     |
| 05-UAT.md has >= 30 checkboxes                                     | `grep -c '\[ \]' 05-UAT.md`                                                                            | 50                     | ✓ PASS     |
| sandbox.wsb has HostFolder + SandboxFolder + ReadOnly              | `grep -E '<HostFolder>\|<SandboxFolder>\|<ReadOnly>' sandbox.wsb`                                      | 3 matches              | ✓ PASS     |
| Running the actual sandbox `-FullTest` end-to-end                   | `pwsh tests/sandbox/run-sandbox-test.ps1 -FullTest`                                                    | Not runnable in Linux executor sandbox | ? SKIP |
| CI workflows green                                                  | `gh run list --workflow=... --json conclusion`                                                         | No gh auth             | ? SKIP     |

Runnable checks all pass. Skipped checks are precisely the runtime gates routed to `human_verification`.

### Human Verification Required

See the `human_verification:` block in the YAML frontmatter at the top of this file. Five items, each with exact copy-paste commands:

1. **REL-01 CI trigger + green-light** — three `gh workflow run` commands + three `gh run list ... conclusion` assertions. Run from marcwin with `gh auth status` clean.
2. **REL-02 `-FullTest` runtime** — compile installer on host, run `pwsh tests\sandbox\run-sandbox-test.ps1 -FullTest`, expect `REL-02 FULL TEST PASSED` banner.
3. **REL-05 tag push + release verification** — `git tag -a v2.0.0`, `git push origin v2.0.0`, watch `installer-release.yml`, `curl -IL` on stable URL, `gh release view v2.0.0`.
4. **REL-06 UAT session** — follow `05-UAT.md` end-to-end on marcwin; the ship gate is a Gmail draft appearing after a Win32 "Send to Mail recipient" action.
5. **REL-07 milestone re-archive** — `/gsd:complete-milestone v2.0.0`, verify `STATE.md` shows `milestone_complete`, `MILESTONES.md` has v2.0.0 entry, archived phase dirs exist.

### Gaps Summary

**None at the executor-verifiable level.** The Phase 5 executor output is complete:

- REL-04 is fixed in code (one-line forward-slash swap, verified by grep).
- REL-02 source artifacts exist and are substantive (sandbox.wsb declarative config, install-and-verify.ps1 with all 6 HKLM + 4 file assertions, hardened -FullTest branch in run-sandbox-test.ps1, tests/sandbox/README.md documentation).
- REL-03 is complete in README.md (end-user Installation/Usage/Uninstall/Privacy/Development sections, byte-identical download URL, SmartScreen walkthrough matching release-template.md, legacy dev-one-liner removed from end-user flow but preserved in Development section).
- REL-01/REL-05/REL-06/REL-07 are fully documented in `05-MANUAL-STEPS.md` + `05-UAT.md` as copy-pasteable command sequences — which is the correct executor output per D-02 in `05-CONTEXT.md`.

The phase's goal ("source-complete → actually shipped") cannot be reached without Marc running the documented manual sequence; that is by design for a release cut. Status is `human_needed`, not `gaps_found`, because every gap between current state and the phase goal maps to an item already listed in `human_verification` with an exact command. The verifier has no blocking issues to surface to a `/gsd-plan-phase --gaps` replan.

---

_Verified: 2026-04-11T08:30:00Z_
_Verifier: Claude (gsd-verifier)_
