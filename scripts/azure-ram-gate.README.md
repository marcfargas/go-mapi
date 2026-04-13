# `azure-ram-gate.ps1` — Phase 7 RAM gate automation

This script provisions a one-shot Windows Server 2022 Datacenter VM on Azure, runs the
go-mapi RAM measurement protocol with N concurrent in-VM sessions, pulls the CSV back,
and destroys the resource group. Azure CLI + PowerShell only — **no Terraform**.

Paired script: [`measure-ram.ps1`](./measure-ram.ps1) — does the actual sampling inside
the VM and the local CSV aggregation.

---

## Prerequisites (one-time, local dev machine)

1. **Azure CLI ≥ 2.50**
   ```powershell
   winget install Microsoft.AzureCLI   # or see https://aka.ms/installazurecliwindows
   az --version                         # confirm 2.50+
   ```
2. **Active `az login` session**
   ```powershell
   az login
   az account show                      # verify the active subscription
   az account set --subscription <id>   # if multiple subscriptions
   ```
3. **Plan 03 binary built and present at `src/app/build/bin/go-mapi.exe`** (see
   `.planning/phases/07-wails-shell-ram-gate/07-03-SUMMARY.md`).
4. **Subscription has permission to create VMs in the chosen region** (default
   `westeurope`; override with `-Location`).

---

## Parameters

| Param | Default | Purpose |
|-------|---------|---------|
| `-N` | `5` | Concurrent session count. `5`+ for full PASS; `2` for PROVISIONAL per REVIEWS HIGH. |
| `-SubscriptionId` | *(active)* | Override `az` active subscription for this run. |
| `-Location` | `westeurope` | Azure region for the resource group / VM. |
| `-VmSize` | `Standard_D4s_v3` | 4 vCPU / 16 GB RAM — sized for ≥10 concurrent sessions. |
| `-RgName` | `rg-gomapi-ramgate-<UTC timestamp>` | Resource group name (ephemeral). |
| `-BinaryPath` | `src/app/build/bin/go-mapi.exe` | Path to the Plan 03 binary (relative to repo root). |
| `-MeasureScript` | `scripts/measure-ram.ps1` | On-VM benchmark script to upload. |
| `-CsvOut` | `docs/measurements/phase-07-ram-gate.csv` | Where to write the pulled CSV. |
| `-Confirm` | *(required)* | Must be set — script refuses to proceed without it (cost gate). |
| `-KeepResourceGroup` | *(off)* | Debug-only. Skips the teardown. Manual cleanup required. |

---

## Expected cost

- ~**$0.41** for a 1-hour N=5 run on `Standard_D4s_v3` (Windows Server 2022 Datacenter)
  in `westeurope`. Cost is dominated by the VM hourly rate (~$0.40/hr) + trivial
  storage/egress; it **does not scale with N** — the VM is sized once for the entire
  concurrent-session batch.
- Azure bundles the Windows Server OS license in the hourly rate (AWS/GCP would require
  separate RDS/CAL purchases).
- Actual cost is printed at the end of the run when available.

---

## Teardown behaviour

- `az group delete --name $RgName --yes --no-wait` fires in the script's `finally`
  block. If the script dies (Ctrl-C, crash, network glitch), teardown still runs.
- If `-KeepResourceGroup` is set, the script warns loudly and **you must clean up
  manually**:
  ```powershell
  az group delete --name <rg> --yes --no-wait
  ```
- Resource group name is echoed to `stderr` immediately after `az group create`, so even
  if the rest of the script crashes you have the name handy for cleanup.

---

## How to run

From the repo root:

```powershell
# Full N=5 PASS-path run
pwsh scripts/azure-ram-gate.ps1 -N 5 -Confirm

# Cheaper N=2 PROVISIONAL-path run (requires explicit acknowledgement at Task 3)
pwsh scripts/azure-ram-gate.ps1 -N 2 -Confirm
```

Expected wall time: 45–60 min (≈5 min provision + ≈45 min measurement loop + ≈1 min
teardown).

Exit codes:

| Code | Meaning |
|------|---------|
| 0 | Success — CSV pulled, resource group destroyed (or kept per flag). |
| 2 | Preflight failure (az CLI missing, not logged in, `-Confirm` absent, binary missing). |
| 3 | `az vm create` failed. |
| 4 | Bootstrap / upload `run-command` failed. |
| 5 | Measurement timeout (flag never appeared within 30 min poll ceiling). |
| 6 | CSV retrieval failed. |

After the script returns 0, aggregate locally:

```powershell
pwsh scripts/measure-ram.ps1 -Aggregate docs/measurements/phase-07-ram-gate.csv
```

---

## Measurement gotchas (read before modifying)

1. **`Performance Log Users` group membership is mandatory.** Every session user
   (`ramtest1..ramtestN`) is added to that local group during bootstrap; if the
   assignment is edited out, `Win32_PerfRawData_PerfProc_Process` returns empty and the
   CSV fills with zeros **silently**. The bootstrap script asserts membership via
   `Get-LocalGroupMember` and throws if missing — do not weaken that check.
2. **`Get-Counter` instance-name collisions** across multiple `go-mapi.exe` processes
   owned by different session users are why we key on `IDProcess` via
   `Win32_PerfRawData_PerfProc_Process` instead of `Get-Counter`. This gives unambiguous
   per-PID resolution without toggling the PerfMon "Show process identifier" registry
   setting on the VM.
3. **Multi-process correlation.** Per-session metric is the **sum** of `go-mapi.exe`
   Private WS + every `msedgewebview2.exe` child whose `ParentProcessId` equals the
   go-mapi PID. Main-process-only is kept as a secondary diagnostic column
   (`go_mapi_ws_mb`) but the gate applies to `total_ws_mb`. Measuring only the main
   process would undercount substantially (REVIEWS HIGH).
4. **`az vm run-command invoke` payload cap (~32 KB script).** The binary upload is
   base64-inline when size allows; otherwise the script falls back to a transient
   Storage Account + SAS URL and `Invoke-WebRequest` inside the VM. Which path was taken
   on any given run is printed to the console and should be recorded in
   `07-VERIFICATION.md` for reproducibility.
5. **Scheduled-task sessions are NOT true RDS sessions.** They are per-user HDESKTOP
   processes spawned via `Register-ScheduledTask -Principal $user -LogonType Password`.
   Good enough for Private Working Set measurement — the OS still allocates per-session
   kernel structures — but differs from real RDP/RDS logon session type. This caveat is
   documented honestly in `07-VERIFICATION.md` and carries forward with any PASS /
   PROVISIONAL verdict. Driving mstsc/FreeRDP externally would be more accurate but is
   race-prone and fragile; the scheduled-task approach is the explicit locked decision
   (see memory `project_phase7_ram_gate_azure.md`).
6. **Binary integrity.** SHA256 of the local `go-mapi.exe` is computed before upload and
   verified against the VM copy. Mismatch = hard failure.
7. **Admin password.** Generated with `System.Web.Security.Membership.GeneratePassword`
   at runtime and held in memory only — never written to disk, CSV, or log. The VM has
   `--nsg-rule NONE` (no inbound 3389 exposed); all orchestration is via `az vm
   run-command invoke` over the Azure control plane.

---

## Re-running

- Subsequent runs overwrite `docs/measurements/phase-07-ram-gate.csv` by default (pass a
  different `-CsvOut` to preserve a prior run).
- `07-VERIFICATION.md` is **appended to**, not overwritten, across re-runs — variance
  across runs is valuable data for the verdict.

---

## Safety recap

- VM has no inbound 3389. All orchestration via the Azure control plane.
- Admin password memory-only, never persisted.
- Resource group is destroyed in `finally` (unless `-KeepResourceGroup`).
- CSV contains only process names, PIDs, Private WS bytes, timestamps, and
  `ramtest1..ramtestN` local-user names. No PII. Safe to commit.
