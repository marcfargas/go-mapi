---
phase: 10-installer-migration
plan: 05
subsystem: installer-ci
tags:
  - installer
  - pester
  - ci
  - smoke-test
  - aumid-verification

dependency-graph:
  requires:
    - plan 10-01 (NSIS script deposits go-mapi.exe, go-mapi.dll, uninstall.exe under $INSTDIR)
    - plan 10-02 (webview2_check in Wails app — not exercised by smoke but co-built here)
    - plan 10-03 (Start Menu shortcut + AUMID stamp + firewall rule — items 5, 6)
    - plan 10-04 (uninstall scrub: firewall delete, %APPDATA% gone, cmdkey colon target — items 10, 11, 12)
  provides:
    - "src/installer/tests/installer.Tests.ps1 — Pester 5 13-item D-21 smoke suite"
    - "src/installer/tests/AumidReader.ps1 — reusable inline-C# IPropertyStore AUMID reader"
    - ".github/workflows/installer-smoke.yml — per-PR + develop/main CI gate"
  affects:
    - "Future NSIS edits that touch registry keys, shortcut, firewall, cmdkey scrub now have an automated regression gate"
    - "Plan 10-06 release workflow inherits the same ldflags + makensis recipe (smoke is the canary for release mechanics)"

tech-stack:
  added:
    - "Pester 5 (pre-installed on windows-latest per D-30 — no install step)"
    - "NSIS 3.10 (pre-installed on windows-latest; choco fallback in workflow)"
  patterns:
    - "Inline C# + Add-Type + IPersistFile + IPropertyStore for stable AUMID reads (RESEARCH §Pitfall 2 — NOT Get-StartApps)"
    - "Pester 5 config-API invocation via New-PesterConfiguration + Invoke-Pester -Configuration (NOT Pester 4 -EnableExit)"
    - "Start-Process -ArgumentList '/S','/D=<path>' array form for NSIS silent install (Pitfall 5)"
    - "GitHub Actions path-filter on workflow triggers to scope smoke-gate to installer-relevant PRs"

key-files:
  created:
    - "src/installer/tests/AumidReader.ps1 (113 lines)"
    - "src/installer/tests/installer.Tests.ps1 (153 lines)"
    - ".github/workflows/installer-smoke.yml (120 lines)"
  modified: []

decisions:
  - "AUMID verification uses inline-C# IPropertyStore read, NOT Get-StartApps — Get-StartApps has an indexing delay after shortcut creation that makes Pester flake (RESEARCH §Anti-Patterns)"
  - "AumidReader.ps1 extracted as a dedicated helper file (not inlined in installer.Tests.ps1) — keeps the Pester file focused on assertions, and the reader is reusable for future tests"
  - "Path filter on workflow triggers includes the workflow file itself (self-include) so workflow edits re-trigger the job — matches GHA best practice for workflows-that-test-their-own-edits"
  - "Empty OAuth secrets on forked-PR builds are intentional: Pester doesn't launch the app (D-22 excludes live-UI tests), so binaries built with empty creds still install + uninstall correctly, which is the entire smoke surface"
  - "Path resolution for the installer artifact: Join-Path $PSScriptRoot '..\..\..\go-mapi-setup.exe' — makensis emits go-mapi-setup.exe at the repo root (the current working directory when the workflow runs makensis)"

metrics:
  duration: "~4 minutes (executor wall-time on this agent)"
  completed_date: 2026-04-20
  tasks_completed: 3
  commits: 3
  files_created: 3
  files_modified: 0
---

# Phase 10 Plan 05: Pester 5 smoke test + AUMID reader + CI smoke workflow Summary

One-liner: Adds a per-PR + develop/main CI gate that compiles the NSIS installer end-to-end on windows-latest and round-trips install/uninstall through a Pester 5 smoke suite covering all 13 D-21 invariants, with AUMID verification done via a reusable inline-C# IPropertyStore helper (NOT Get-StartApps).

## Objective

Close INST-07. Create three new files:

1. **`src/installer/tests/AumidReader.ps1`** — reusable helper that defines `Get-ShortcutAumid` via inline `Add-Type` C# (IPersistFile + IPropertyStore + PropVariantToString). Stable primitive for reading `PKEY_AppUserModel_ID` from a `.lnk` without the Get-StartApps indexing-delay flakiness.
2. **`src/installer/tests/installer.Tests.ps1`** — Pester 5 suite with `Describe "go-mapi installer round-trip"` + two `Context` blocks ("Silent install" items 1–6, "Silent uninstall" items 7–13). Covers the full D-21 13-item checklist.
3. **`.github/workflows/installer-smoke.yml`** — CI workflow that, on push to main/develop + every PR (path-filtered to installer/interceptor/app + self), builds the DLL + Wails app + NSIS installer and runs the Pester suite on a windows-latest runner. Blocks merges on failure.

## What changed

### New files

| File | Lines | Purpose |
|------|-------|---------|
| `src/installer/tests/AumidReader.ps1` | 113 | Inline-C# IPropertyStore reader — defines `Get-ShortcutAumid $path` callable against any .lnk |
| `src/installer/tests/installer.Tests.ps1` | 153 | Pester 5 D-21 smoke suite — 13 `It` blocks split across 2 Contexts |
| `.github/workflows/installer-smoke.yml` | 120 | Per-PR + develop/main push CI gate — path-filtered, windows-latest, 3 Pester steps |

### Cross-plan literal-match guarantee

The smoke test is only useful if its assertions match what the NSIS installer actually writes. This plan hardcodes three strings that MUST match byte-for-byte across 10-03, 10-04, and 10-05:

| Literal | Produced by | Asserted by |
|---------|-------------|-------------|
| `com.marcfargas.gomapi` (AUMID) | `src/installer/go-mapi.nsi:36` + `ApplicationID::Set` call | `installer.Tests.ps1` item 5 |
| `go-mapi OAuth loopback` (firewall rule name) | `src/installer/go-mapi.nsi:346` (AddFirewallRule) | `installer.Tests.ps1` items 6 + 10 |
| `go-mapi:oauth-tokens` (cmdkey target, COLON) | `src/installer/go-mapi.nsi:398` (cmdkey /delete) | `installer.Tests.ps1` item 12 |

Verified via grep of `src/installer/go-mapi.nsi` before implementation — all three strings are already present in the installer (from plans 10-03 and 10-04), so the smoke suite will pass literal-match on first CI run.

The slash form `go-mapi/oauth-tokens` (CONTEXT.md's original error, superseded per PATTERNS.md §Planner-Facing Correction Log) appears in NONE of the three files — verified by grep.

### Why `Get-StartApps` was rejected in favor of inline C#

`Get-StartApps -Name "go-mapi"` returns a `StartApp` object with an `AppID` property — simpler to call than the COM acrobatics. It was rejected for two reasons:

1. **Indexing delay:** On a freshly-installed shortcut, Windows Search indexing takes non-deterministic time (observed: seconds to minutes) before `Get-StartApps` surfaces the new `.lnk`. In a Pester suite that installs and immediately checks, this produces flaky failures.
2. **Not canonical:** `Get-StartApps` queries the Windows Search index, which populates from the shell namespace. The shortcut's actual `PKEY_AppUserModel_ID` is stored in the `.lnk`'s property store. The canonical source of truth is `IPropertyStore.GetValue(PKEY_AppUserModel_ID)` — which is what the inline C# path hits directly. No timing dependency.

The inline-C# reader mirrors the writer-side code in `scripts/register-dev-aumid.ps1` (IPersistFile + IPropertyStore + PROPVARIANT) but in read-only mode: `pf.Load(..., STGM_READ)` + `ps.GetValue(ref key, out pv)` + `PropVariantToString(...)`. Lifecycle cleanup is handled in nested `try/finally` blocks (`PropVariantClear` then `ReleaseComObject`) so repeated calls across `It` blocks don't leak.

### How the path filter keeps the smoke gate focused

The workflow triggers on `push` (main + develop) and `pull_request`, both with a `paths:` filter:

```yaml
paths:
  - 'src/installer/**'
  - 'src/interceptor/**'
  - 'src/app/**'
  - '.github/workflows/installer-smoke.yml'
```

Rationale:
- `src/installer/**` — NSIS script, tests, vendored plugins/bootstrapper changes must re-validate.
- `src/interceptor/**` — DLL changes flow into the installer bundle; re-validate.
- `src/app/**` — Wails binary changes flow into the installer bundle; re-validate.
- `.github/workflows/installer-smoke.yml` — self-include so workflow edits re-trigger the job (GHA best practice for self-testing workflows).

Doc-only PRs (README.md, .planning/, etc.) skip the ~3-minute installer round-trip. Saves CI budget; reduces merge-blocker fatigue on documentation churn.

## Deviations from Plan

### Deviations from RESEARCH §Code Examples 11, 12, 13

**None substantive.** Code tracks the research examples closely with three minor additions:

1. **Section-header comment blocks added to all three files** (naming each D-21 item under `Silent install` / `Silent uninstall`; listing cross-plan literals and their producers). RESEARCH Example 11 was a skeleton; the implementation adds orientation comments for future maintainers — not a behavioral change.
2. **Idempotent dot-source guard on AumidReader** (`if (-not ('GoMapi.AumidReader.Reader' -as [type]))`) — not in RESEARCH Example 12 literally, but the research note on "Add-Type idempotency" implied it. Added defensively so re-dot-sourcing during iterative test development doesn't error with "type already exists".
3. **`actions/upload-artifact@v4` step with `if: always()`** — RESEARCH Example 13 did not include artifact upload. Added to preserve `go-mapi-setup.exe` for 7 days on every run (including failures), so humans can manually debug red CI runs via the uploaded binary. Matches the pattern in `.github/workflows/build.yml`.

### Deviations driven by CLAUDE.md / project rules

**None.** All three files comply with project conventions: LF line endings (git CRLF warning is expected on Windows checkout), LGPL-3.0 header unnecessary for CI/test scaffolding, no secrets-handling violations (OAuth creds are injected via `env:` from repo secrets — never printed).

### Auto-fixed Issues

**None.** All three tasks executed exactly as the plan described. No bugs discovered, no missing critical functionality, no blocking issues.

### Scope boundary observations (not fixed — pre-existing)

- CONTEXT.md D-15 says `-X github.com/marcfargas/go-mapi/src/app.aumidOverride=...` — PATTERNS.md §Shared Pattern 4 corrects this to `-X main.aumidOverride=...` (since `src/app/toast.go` is `package main`). The smoke workflow uses the corrected form `-X main.aumidOverride=com.marcfargas.gomapi` per PATTERNS guidance. This is a planning-document inconsistency already captured in PATTERNS.md §Planner-Facing Correction Log — not a deviation introduced here.

## Verification

**Automated checks performed:**

- `wc -l` confirms line counts exceed `min_lines` in plan frontmatter (AumidReader: 113 ≥ 80; installer.Tests.ps1: 153 ≥ 150; installer-smoke.yml: 120 ≥ 50).
- `grep -cE 'It +"[0-9]+\.'` confirms exactly 13 numbered `It` blocks in the Pester suite.
- `grep` confirms all three cross-plan literals (`com.marcfargas.gomapi`, `go-mapi OAuth loopback`, `go-mapi:oauth-tokens`) are present in installer.Tests.ps1.
- `grep` confirms the slash form `go-mapi/oauth-tokens` appears NOWHERE.
- `grep` confirms no `Get-StartApps` or `-EnableExit` usage.
- `grep` confirms no `signpath` / `SIGNPATH` reference in installer-smoke.yml (release-only per D-25).
- `grep` confirms no tag trigger (`tags: ['v*']`) in installer-smoke.yml (plan 10-06 owns that).
- `node` YAML-shape check confirms workflow parses and has `jobs.smoke` + `paths:` filter.

**First-run CI expectation:**
After merging, a push to develop modifying any `src/installer/**` path triggers the workflow. Expected: ~3-minute job, exits green. If it's red on first run, diagnose via the uploaded `go-mapi-setup.exe-smoke-<sha>` artifact and the Detailed Pester output in the logs. Most likely failure modes:
- NSIS not on PATH → fallback `choco install nsis` step handles this.
- MinGW version drift → `choco install mingw` pins current stable.
- AUMID test failing → indicates plan 10-03's `ApplicationID::Set` call silently returned non-zero; check DetailPrint output.

**Not verified here:**
- Pester parse-check via PowerShell — not runnable from this executor's shell environment (bash). Will be validated on first CI run (workflow_dispatch available for manual pre-merge test).
- Actual Pester execution — same reason. CI is the authoritative verification.

## Files created/modified

Created:
- `src/installer/tests/AumidReader.ps1`
- `src/installer/tests/installer.Tests.ps1`
- `.github/workflows/installer-smoke.yml`

Modified:
- (none)

## Commits

| Hash | Subject |
|------|---------|
| `b00e932` | feat(10-05): add AumidReader.ps1 inline-C# IPropertyStore helper |
| `50ac6f2` | feat(10-05): add Pester 5 smoke test for installer round-trip |
| `f8d17bb` | ci(10-05): add installer-smoke.yml per-PR Pester gate |

(The final metadata commit that includes this SUMMARY.md will follow.)

## Known Stubs

**None.** All three files are production-ready. The Pester suite covers the full D-21 13-item checklist; no items are placeholders, mocks, or TODOs. The AumidReader exposes a real callable; the workflow is a real blocking CI gate.

## Self-Check: PASSED

- `src/installer/tests/AumidReader.ps1` exists (verified via Grep + `wc -l`).
- `src/installer/tests/installer.Tests.ps1` exists (verified via Read + `wc -l`).
- `.github/workflows/installer-smoke.yml` exists (verified via Read + `wc -l`).
- Commit `b00e932` present in `git log` (verified immediately after commit).
- Commit `50ac6f2` present in `git log` (verified immediately after commit).
- Commit `f8d17bb` present in `git log` (verified immediately after commit).
- All three cross-plan literals present in installer.Tests.ps1 (verified via grep).
- Zero `Get-StartApps` / `-EnableExit` / `go-mapi/oauth-tokens` / `signpath` / tag-trigger matches (verified via grep).
