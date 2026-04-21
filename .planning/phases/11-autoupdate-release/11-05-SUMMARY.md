---
phase: 11-autoupdate-release
plan: 05
subsystem: release-verification
tags: [sandbox, smoke-test, release-verification, evidence]
dependency-graph:
  requires: [11-03]
  provides:
    - windows-sandbox-harness
    - phase-11-smoke-checklist
    - phase-11-evidence-ledger
  affects:
    - plan-11-04-release-cut
tech-stack:
  added:
    - windows-sandbox-wsb
    - powershell-5-harness-script
  patterns:
    - mapped-folder-evidence-path
    - screenshots-before-manual-tail
    - sha256-evidence-manifest
    - installer-source-fallback-chain
key-files:
  created:
    - tests/sandbox/phase11/go-mapi-phase11.wsb
    - tests/sandbox/phase11/Run-Phase11Smoke.ps1
    - tests/sandbox/phase11/Collect-Phase11Evidence.ps1
    - .planning/phases/11-autoupdate-release/11-SMOKE-CHECKLIST.md
    - .planning/phases/11-autoupdate-release/11-SMOKE-EVIDENCE.md
  modified: []
decisions:
  - id: harness-outside-hosted-ci
    description: "Per D-13, the full user-journey smoke lives in Windows Sandbox, NOT in GitHub Actions. The Phase 10 installer-smoke.yml stays lean and MAPI/OAuth-free."
  - id: installer-source-fallback
    description: "Harness tries explicit -InstallerSource, then a pre-staged workflow_dispatch dry-run artifact at C:\\phase11\\installer\\go-mapi-setup.exe, then falls back to https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe."
  - id: screenshots-but-no-oauth-automation
    description: "Harness captures 01-pre-install / 02-post-install / 03-app-launched screenshots automatically (D-15). OAuth consent + MAPI shell trigger + Gmail-drafts-UI verification remain a documented manual tail (D-14)."
  - id: evidence-persists-via-mapped-folder
    description: "The .wsb maps the host tests/sandbox/phase11/ directory into the sandbox at C:\\phase11 with ReadOnly=false, so evidence-<timestamp>/ subdirectories land back on the host filesystem after sandbox teardown."
metrics:
  duration: "~18 min"
  completed: PENDING (blocking checkpoint)
---

# Phase 11 Plan 05: Clean-machine Sandbox Smoke Harness Summary

Windows Sandbox harness for the pre-GA full-user-journey smoke (install ->
sign in -> MAPI trigger -> queue -> Gmail draft -> uninstall) that deliberately
runs outside hosted CI (per D-13) so OAuth + MAPI shell + Gmail UI checks
never contaminate GitHub runners.

## Status

- Task 1 (auto): COMPLETE and committed as `5aeb9d5`.
- Task 2 (checkpoint:human-verify, gate=blocking): PENDING - awaiting the
  human to run the sandbox and fill `11-SMOKE-EVIDENCE.md` with pass/fail
  outcomes for every checklist step.

This Summary documents what Task 1 delivered. It will need a follow-up
amendment (or a second summary block) once Task 2 is approved, to record
the final evidence verdict and any deviations discovered during the actual
clean-machine run.

## What Task 1 delivered

### 1. `tests/sandbox/phase11/go-mapi-phase11.wsb` (52 lines)

Windows Sandbox configuration that:

- maps the host `tests/sandbox/phase11/` into the sandbox at `C:\phase11`
  with `ReadOnly=false` so evidence survives sandbox teardown;
- enables networking (needed for installer download + OAuth consent + Gmail
  draft verification);
- disables printer, audio, video, VGpu redirection to keep the sandbox
  surface small and reproducible;
- keeps clipboard redirection enabled so the human can paste the OAuth
  verification code into the sandbox browser;
- uses `<LogonCommand>` to auto-run `Run-Phase11Smoke.ps1` on login.

### 2. `tests/sandbox/phase11/Run-Phase11Smoke.ps1` (190 lines)

Automated harness that runs inside the sandbox. Key behaviors:

- Creates `C:\phase11\evidence-<timestamp>/` with `screenshots/`, `video/`,
  `logs/` subdirectories.
- Resolves the installer with a three-way fallback: explicit
  `-InstallerSource` parameter -> pre-staged
  `C:\phase11\installer\go-mapi-setup.exe` (used when a `workflow_dispatch`
  dry-run artifact is placed there) -> stable
  `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`.
  Required per the plan's verify snippet - the harness MUST cite at least
  one of those two strings; this one cites both.
- Takes pre-install and post-install screenshots via
  `System.Windows.Forms.Screen.PrimaryScreen.Bounds` + `Bitmap.Save` PNG.
- Runs `go-mapi-setup.exe /S` silently; fails hard on non-zero exit.
- Launches the app from the Start Menu shortcut so the human lands in the
  sign-in screen ready to perform the manual OAuth tail.
- Writes `harness-metadata.md` with the run metadata for the human to
  reference while filling `11-SMOKE-EVIDENCE.md`.

### 3. `tests/sandbox/phase11/Collect-Phase11Evidence.ps1` (~85 lines)

Post-run gatherer. Collects:

- `%APPDATA%\go-mapi\app.log` (OAuth + queue + Gmail activity during the
  manual tail - the single richest signal for pass/fail triage).
- `%LOCALAPPDATA%\go-mapi\` if present.
- `%TEMP%\go-mapi\` snapshot before uninstall (for draft-step debugging).
- NSIS install + uninstall log files.
- Generates `evidence-manifest.json` with a SHA256 hash of every collected
  file so `11-SMOKE-EVIDENCE.md` can reference integrity-verified names.

Privacy baseline (CLAUDE.md + D-15): no OAuth token values and no email
body content are parsed or written - only log lines and file paths.

### 4. `.planning/phases/11-autoupdate-release/11-SMOKE-CHECKLIST.md`

Ten numbered steps (`0. pre-flight` through `9. fill evidence ledger` plus
`10. resume signal`). Each step has checkbox items and an `Evidence` line
stating what screenshot / log / text note must exist to close the step.
Time budget spelled out: roughly 15 minutes wall-clock, roughly 3 minutes
active interaction. OAuth is called out explicitly as the slowest manual
step. The uninstall step spells out the exact PowerShell one-liners the
human must run to verify each artifact is gone.

### 5. `.planning/phases/11-autoupdate-release/11-SMOKE-EVIDENCE.md` (120 lines)

Artifact ledger skeleton with one section per checklist step. Each section
has: expected screenshot/log filenames, structured YES/NO questions for the
operator, a `Verdict` line, and a free-form `Notes` field. Contains all
required substrings per the plan's verify snippet: `install`, `sign in`,
`MAPI`, `queue`, `draft`, `uninstall`. A final-verdict section with three
gate checkboxes closes the file.

## Verification

Ran the plan's automated verify snippet inside the worktree:

```
wsb lines: 52 (need >=20)
Run-Phase11Smoke lines: 190 (need >=120)
evidence lines: 120 (need >=80)
VERIFY OK
```

All five files exist, `.wsb` is valid XML, both PowerShell files tokenize
cleanly (0 parse errors), Run-Phase11Smoke.ps1 cites both
`workflow_dispatch` and `releases/latest/download/go-mapi-setup.exe`, and
SMOKE-EVIDENCE.md contains every required step keyword.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] PowerShell 5.1 misparsed UTF-8 smart punctuation in comments**

- **Found during:** Task 1 verification (`[System.Management.Automation.PSParser]::Tokenize`).
- **Issue:** Em-dash (U+2014) and other smart-punctuation characters written
  by the draft got decoded as Windows-1252 during Tokenize, which then saw
  stray right-double-quote bytes and reported 13 spurious parse errors.
  The plan-level verify snippet specifically asserts parse errors == 0, so
  this was a gate-blocking issue for the Task 1 commit.
- **Fix:** Normalized `Run-Phase11Smoke.ps1` and `Collect-Phase11Evidence.ps1`
  to ASCII (`—` -> `-`, `"`/`"` -> `"`, `'`/`'` -> `'`). The CLAUDE.md
  project-level convention of describing "why not what" in comments is
  preserved; only the punctuation flavor changed.
- **Files modified:** `tests/sandbox/phase11/Run-Phase11Smoke.ps1`,
  `tests/sandbox/phase11/Collect-Phase11Evidence.ps1`.
- **Commit:** `5aeb9d5` (included in the Task 1 atomic commit - the fix
  was applied before the first successful verify).

**2. [Rule 3 - Blocking] `@"..."@` here-string closing marker misaligned**

- **Found during:** Task 1 verification.
- **Issue:** The first draft of `Write-EvidenceHeader` used a here-string
  with the closing `"@` indented inside the function body. PowerShell
  here-strings require the closing marker to be at column 0, and the
  misalignment combined with the smart-quote issue above produced a parse
  error at line 145.
- **Fix:** Rewrote `Write-EvidenceHeader` to build the metadata lines via a
  string array + `-join [Environment]::NewLine` instead of a here-string.
  Simpler, column-agnostic, and indent-robust under future edits.
- **Files modified:** `tests/sandbox/phase11/Run-Phase11Smoke.ps1`.
- **Commit:** `5aeb9d5`.

Both fixes are correctness issues caught by the plan's own verify snippet;
no scope expansion.

## What happens next (Task 2 - blocking checkpoint)

A separate checkpoint message is being returned to the orchestrator
describing the exact manual steps. Nothing else gets built until the
human runs the sandbox, fills `11-SMOKE-EVIDENCE.md` with real evidence,
and replies `approved` (or describes the failing step).

Per plan 11-05 `<verification>`: "The deliverable is not complete until
`11-SMOKE-EVIDENCE.md` contains a full pass record from a clean-machine
run and the user checkpoint is approved. Public GA release work in 11-04
stays blocked on that result."

## Self-Check: PASSED

- `tests/sandbox/phase11/go-mapi-phase11.wsb`: FOUND (52 lines, valid XML)
- `tests/sandbox/phase11/Run-Phase11Smoke.ps1`: FOUND (190 lines, 0 parse errors, cites both installer sources)
- `tests/sandbox/phase11/Collect-Phase11Evidence.ps1`: FOUND (0 parse errors)
- `.planning/phases/11-autoupdate-release/11-SMOKE-CHECKLIST.md`: FOUND
- `.planning/phases/11-autoupdate-release/11-SMOKE-EVIDENCE.md`: FOUND (120 lines, all six required keywords present)
- Commit `5aeb9d5`: FOUND in git log
