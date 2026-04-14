# Phase 7 RAM Gate — Measurement Writeup

**Date:** 2026-04-14
**Verdict:** PASS (43.24 MB mean per session vs 80 MB threshold)
**Full report:** [.planning/phases/07-wails-shell-ram-gate/07-VERIFICATION.md](../../.planning/phases/07-wails-shell-ram-gate/07-VERIFICATION.md)
**Raw CSV:** [phase-07-ram-gate.csv](phase-07-ram-gate.csv)

## What was measured

Per-session Private Working Set of go-mapi.exe (Wails + WebView2 Evergreen) under 5 concurrent independent user sessions on a Windows Server 2022 VM in Azure. Each session owns its own go-mapi.exe main process plus msedgewebview2.exe children (correlated via ParentProcessId). The gate metric is the **sum** at the 5-minute idle-post-webview-init checkpoint.

## Result

| Metric | Value |
|---|---|
| Mean per-session total Private WS (idle-post-webview, iter 1, n=4 clean samples) | **43.24 MB** |
| Max per-session total | 43.77 MB |
| Stddev | 0.39 MB (<1% of mean) |
| Gate threshold (D-04) | 80 MB |
| Stretch goal (D-04) | ≤ 30 MB |

**Verdict: PASS**. Comfortable margin to the 80 MB gate. Stretch not achieved.

## Reproduce

```powershell
# Prereqs: Azure CLI ≥ 2.50, az login, Plan 03 binary built for windows/amd64
cd src/app && wails build -clean -platform windows/amd64 && cd ../..
pwsh scripts/azure-ram-gate.ps1 -N 5 -Confirm
```

~45 min wall time, ~$0.50 Azure spend, fully automated provision → measure → teardown.

## Caveats

See [07-VERIFICATION.md §Methodology Caveats](../../.planning/phases/07-wails-shell-ram-gate/07-VERIFICATION.md#methodology-caveats-transparency) for full transparency on:

- Spurious sub-2 MB rows from `--show-window` trigger processes
- Iter 2/3 single-instance-mutex race (discarded; iter 1 authoritative)
- ramtest5 iter-1 capture race (N=4 effective)
- Scheduled-task sessions ≠ true RDS sessions (proxy measurement)

None of these invalidate the iter-1 gate reading, which is tight (<1% stddev across 4 sessions) and well under threshold.

## Files

| Path | Role |
|---|---|
| `scripts/azure-ram-gate.ps1` | Azure CLI + PowerShell orchestration wrapper (provision → bootstrap → measure → pull → teardown). NO Terraform. |
| `scripts/measure-ram.ps1` | On-VM worker + orchestrator + aggregate mode. |
| `scripts/azure-ram-gate.README.md` | Prerequisites, parameters, cost, teardown notes. |
| `docs/measurements/phase-07-ram-gate.csv` | Raw sample rows (8 columns, 39 rows). |
| `.planning/phases/07-wails-shell-ram-gate/07-VERIFICATION.md` | Full gate verification + caveats + per-requirement verification. |
