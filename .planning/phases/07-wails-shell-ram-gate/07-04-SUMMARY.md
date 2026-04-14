---
phase: 07-wails-shell-ram-gate
plan: 04
completed: 2026-04-14
verdict: PASS
requirements_verified: [QUAL-01, QUAL-02]
---

# Plan 04 Summary — RAM Measurement Gate

## Outcome

**PASS.** Mean per-session Private Working Set at 5-min idle-post-WebView2-init under 5 concurrent in-VM sessions: **43.24 MB** (n=4 clean samples, stddev 0.39 MB). Well under the 80 MB D-04 gate. Stretch (≤30 MB) not met. **Phase 8 unblocked.**

Full report: [07-VERIFICATION.md](07-VERIFICATION.md).

## Delivered

| Artifact | Path |
|---|---|
| Azure orchestration wrapper | `scripts/azure-ram-gate.ps1` |
| On-VM benchmark script | `scripts/measure-ram.ps1` |
| Run prerequisites / usage | `scripts/azure-ram-gate.README.md` |
| Raw measurement CSV | `docs/measurements/phase-07-ram-gate.csv` (39 rows) |
| Measurement writeup | `docs/measurements/phase-07-ram-gate.md` |
| Phase verification | `.planning/phases/07-wails-shell-ram-gate/07-VERIFICATION.md` |

## What happened during execution

The scripts written in Task 1 were sound in design but hit a cascade of real-world Azure / PowerShell / Windows-Server-2022 edge cases during Task 2. Each was diagnosed and fixed in a small atomic commit before the next run:

| Commit | Fix |
|---|---|
| `4797e3e` | Task 1 — initial scripts authored |
| `9b867d2` | Replaced `System.Web.Security.Membership.GeneratePassword` with `RandomNumberGenerator` (System.Web unavailable on .NET Core / pwsh 7) |
| `11deaa1` | Shortened VM computer name to ≤15 chars (`gomapi-ramgate`) |
| `f00c966` | ASCII-only in bootstrap here-string (em-dash got mangled to curly quote in cp1252 reinterpretation, broke PS parser) |
| `94bc753` | `\| Out-String` every `az vm run-command invoke` capture before regex (`-notmatch` over array returns non-matching elements, not inverse bool) |
| `5f64f2f` | Added `-Smoke` mode for fast pipeline validation; bumped `-PollTimeoutMinutes` default from 30 to 60 |
| `41104a6` | `icacls C:\gomapi /grant Users:M` after mkdir (non-admin workers couldn't write CSV fragments otherwise) |
| `b52999e` | Added `startup-debug.log` at the very top of measure-ram.ps1 to diagnose silent script-loader failures |
| `5fa1c05` | **Root cause of the "silent exit 1" mystery**: stripped all non-ASCII from measure-ram.ps1. PS 5.1 on WS2022 reads .ps1 files as cp1252 without BOM → em-dash bytes `E2 80 94` became `aEUR"` → embedded `"` broke brace matching → parse error → powershell.exe exited 1 before any script body ran |
| `917f022` | Dropped manual Out-File to the same path as Start-Transcript (exclusive-lock deadlock); use Write-Output instead, transcript captures |
| `83bebe5` | `@(Get-ChildItem ...)` for empty-array safety under StrictMode |
| `976ec0f` | Scheduled task trigger pushed 10 years out (double-fire race with explicit Start-ScheduledTask was wiping CSV fragments) |
| `7fa0756` | Simplified CSV pull: drop base64 marker framing, read StdOut message directly after ConvertFrom-Json |

Final successful run: `pwsh scripts/azure-ram-gate.ps1 -N 5 -Confirm` → ~45 min wall time, ~$0.50 Azure spend, full provision → bootstrap → measure → pull → teardown pipeline, 39-row canonical CSV retrieved.

## Known methodology issues in the measurement

Recorded transparently in 07-VERIFICATION.md §Methodology Caveats. Summary:

1. **Iter 2/3 measurements are unusable** — after the worker's `Stop-Process -Force` between iterations, the single-instance event/mutex from the killed process lingers; iter 2's fresh go-mapi.exe self-detects as "secondary" and exits early without WebView2 initialising. Iter 1 remains authoritative and gives tight results (<1% stddev across 4 sessions).
2. **Spurious ~1.8 MB rows** from the transient `--show-window` trigger process occasionally captured by Sample-Session. Excluded from the gate calculation.
3. **ramtest5 iter-1 has incomplete capture** — scheduled task scheduling jitter delayed it past the iter-1 sample windows. N=4 effective.
4. **Scheduled-task sessions ≠ true RDS sessions** — D-02 tradeoff accepted during research (2026-04-13). This is a strong proxy, not full RDS validation.

None of these invalidate the PASS verdict on iter-1 data. User explicitly accepted the PASS reading (vs downgrading to PROVISIONAL over the N=4 ramtest5 miss).

**Follow-up for a future phase**: patch `measure-ram.ps1` to wait for named-event cleanup (e.g. `Start-Sleep 10` after `Stop-Process`) or use distinct instance IDs per iteration. Would enable 3×N samples per session instead of 1×N. Not urgent — gate is PASSED with comfortable margin already.

## Requirement verification

- **QUAL-01**: Per-instance RAM ≤ 80 MB under 5-10 concurrent RDS-like sessions → **VERIFIED** (43.24 MB mean, n=4, on 5 concurrent in-VM sessions)
- **QUAL-02**: App runs without Chrome/Edge browser dependency; only WebView2 runtime required → **VERIFIED** (measured on WS2022 VM with only WebView2 Evergreen installed; no Edge/Chrome browsers)

## State updates

- `STATE.md`: Phase 07 marked complete, progress 0% → 20%, "RAM profile unvalidated" blocker moved to Resolved
- `ROADMAP.md`: Phase 7 checkbox ticked with PASS verdict noted; Plan 04 line updated (Azure WS2022, three-outcome verdict); Phase 8 marked UNBLOCKED

## Next

**Phase 8 planning is cleared to start.** Run `/gsd-plan-phase 8` for OAuth + Credentials (AUTH-01..07, QUAL-03). The 4-8 week Google OAuth verification dependency (AUTH-06) should be submitted on day 1.
