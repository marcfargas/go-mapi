---
phase: 05-release-cut
fixed_at: 2026-04-11T00:00:00Z
review_path: .planning/phases/05-release-cut/05-REVIEW.md
iteration: 1
findings_in_scope: 2
fixed: 2
skipped: 0
status: all_fixed
---

# Phase 05: Code Review Fix Report

**Fixed at:** 2026-04-11
**Source review:** `.planning/phases/05-release-cut/05-REVIEW.md`
**Iteration:** 1

**Summary:**
- Findings in scope: 2 (critical + warning)
- Fixed: 2
- Skipped: 0

Scope was limited to Critical and Warning findings. The six Info findings
(IN-01..IN-06) were not addressed in this pass.

## Fixed Issues

### WR-02: `wsb list --raw` / `wsb start --raw` output piped to `ConvertFrom-Json` with merged stderr can throw under `Stop` preference

**Files modified:** `tests/sandbox/run-sandbox-test.ps1`
**Commit:** `17003a6`
**Applied fix:** Replaced both `wsb list --raw 2>&1 | ConvertFrom-Json`
and `wsb start --raw 2>&1 | ConvertFrom-Json` with defensive parse blocks
that (a) redirect stderr to `$null` instead of merging it into stdout,
(b) guard on `$LASTEXITCODE` and empty output, and (c) wrap the
`ConvertFrom-Json` call in `try`/`catch` with `-ErrorAction Stop`. The
`list` path now warns and continues assuming no existing sandbox when
the parse fails (non-fatal pre-flight); the `start` path still hard-fails
since the sandbox Id is required for every downstream step, but now with
a clear error message and the raw output printed instead of a cryptic
`Conversion from JSON failed` thrown under `$ErrorActionPreference =
"Stop"`.

Scope note: the review text mentioned the same pattern applies to
`Invoke-SandboxCommand`'s `wsb exec --raw` on line 68, but that specific
case is tracked separately as **IN-05** (info severity) and was left
in place to stay within the critical_warning fix scope.

### WR-01: `-FullTest` runs `setup.ps1` but `tests/sandbox/README.md` does not document this

**Files modified:** `tests/sandbox/run-sandbox-test.ps1`
**Commit:** `a523bda`
**Applied fix:** Dropped `-or $FullTest` from the setup-step guard so the
WinAppDriver install only runs when `-SetupOnly` is explicitly passed.
This aligns the actual behavior with the 8-step `-FullTest` narrative in
`tests/sandbox/README.md` (which never mentions WinAppDriver) and
removes the unchecked `$setupSuccess` fall-through that would have
silently continued into `[5/5]` even after a failed setup. Also added an
explicit failure branch inside the `-SetupOnly` block: if
`Invoke-SandboxCommand` reports a setup failure, the orchestrator now
prints `=== SETUP FAILED ===`, stops the sandbox (unless `-KeepRunning`
is set), and exits 1. The step-counter drift (`[4/4]` vs `[5/5]`) noted
in passing is tracked separately as **IN-01** and was intentionally left
untouched to stay within the critical_warning fix scope.

---

_Fixed: 2026-04-11_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
