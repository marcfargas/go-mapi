---
name: go-mapi-crabbox
description: Validate go-mapi on a fresh Crabbox Azure Windows VM when work touches the interceptor DLL, installer/elevation, or Wails/WebView2 E2E.
---

# go-mapi Crabbox Windows validation

Use this project skill for a live Windows validation run. The local worktree is
canonical; a leased VM is disposable. It supplements the system `crabbox`,
`crabbox-azure-leasing`, and `rdpilot` skills rather than copying their
provider rules.

Before changing a VM, read [Windows readiness](references/windows-readiness.md).

## Known-good local contract

Use the existing local Azure CLI login and Crabbox environment; do not print or
copy credentials. The verified subscription is `Chispa Sideral`
(`e0f87f51-4d5b-4d6f-9a5e-345283edc4a5`), tenant
`7a7c17e7-4876-40f9-b484-8b862dba7d93`, with lease resources in
`CRABBOX-LEASES`. Source `/home/marc/.config/crabbox/.env`, set
`CRABBOX_AZURE_LOCATION=westeurope`, and let Crabbox use the existing Azure CLI
session. Use `--provider azure --target windows --windows-mode normal` and
`Standard_D2als_v7`; record the returned canonical `cbx_...` ID.

Use a candidate that includes the current native-Windows workspace-owner input
repair. On this image, a witnessed PowerShell command receives immediate EOF
for a binary stdin payload even though direct SSH stdin works. Input-bearing
commands therefore use the direct transport while the enclosing workspace
owner remains acquired and renewed; no-input and background operations retain
their witnesses. Before a live run record the candidate SHA-256 and receipt.

A successful sync requires a direct remote check of the expected source files
and no live workspace-owner process. If Git seeding is enabled, also require
matching HEAD, `git diff --quiet`, and expected porcelain. Do not require a
`.git` directory after a deliberately Git-seed-disabled archive-only probe.

The checked-in MIME goldens deliberately retain CRLF. Preserve that with the
root `.gitattributes` `-text` rule; do not regenerate them through a checkout
that normalizes line endings.

## Scope

Windows is required for changes affecting the x64/x86 MAPI interceptor,
machine-wide installation/elevation, WebView2, or the installed product path.
Frontend-only checks may run elsewhere, but do not represent this lane.

Keep these validation layers distinct:

1. interceptor x64 and x86 configure/CTest and matching DLL load/call checks;
2. Go, frontend, Wails, package, release-hygiene, and installer-Pester gates;
3. interactive desktop WebView2 E2E; and
4. installed DLL -> `%LOCALAPPDATA%` queue -> watcher -> Wails integration.

No layer substitutes for another. In particular, current Playwright fixtures
that write queue JSON directly do not prove the interceptor path.

## Ownership, evidence, and cleanup

Snapshot existing lease inventory first. Create an owned VM with a unique
timestamped slug, record its returned canonical `cbx_...` ID immediately, and
use that ID for every subsequent Crabbox command. Never run on, reclaim, or
stop a lease present in the initial inventory.

Write receipts, PowerShell output, screenshots, artifact hashes, and teardown
queries outside the worktree. Do not synchronize `.env.local` or place OAuth,
SAS, RDP, or Azure secrets in evidence.

Stop an owned lease by canonical ID, then independently query Azure for that
exact lease tag and recorded resource IDs. Do not delete shared VNet, NSG, or
storage infrastructure. If Crabbox rejects a stale claim, pause the run and
record the failed command before using an exact-resource Azure fallback.

## Session-proven Windows constraints

- Use one task-owned desktop VM at a time. Always specify `--desktop
  --keep=false`, wait several minutes for desktop warmup, and reuse that VM
  sequentially for related validation rather than starting retry leases.
- Crabbox manages the remote desktop credentials. Do not request credentials
  from the user, expose public RDP, change NSG rules, or configure RDPilot for
  this validation lane.
- Run tests that need the interactive Windows user context (including real
  Credential Manager/keyring tests) through Crabbox managed desktop launch.
  Plain SSH may be used only for narrowly scoped source transport or read-only
  diagnostics; it is not a substitute for the desktop-token test path.
- Treat a successful `run --full-resync` as unproven until expected source
  files are present and hashed on the guest. On the observed Windows image,
  normal sync or an archive overlay could report success while omitting source
  files. Use an explicitly authorized, non-destructive per-file base64/
  PowerShell fallback, then hash-check the transferred files. Do not start a
  competing sync while an earlier owner is active.
- `crabbox desktop terminal` may only open Mintty and not execute appended
  commands. First prove the exact command path with a durable marker; use
  `crabbox desktop launch` for managed-desktop command execution when terminal
  does not create that marker. Persist output and an explicit exit marker in a
  VM-local durable log, since `desktop proof` can fail when the guest lacks
  `scp.exe`/SFTP.
- A successful desktop-control command is not evidence that the command reached
  the session. On the observed Windows lease, `desktop launch` returned without
  creating its marker, `desktop terminal` opened Mintty, `desktop paste` plus
  Enter created no marker, `desktop type` was unsupported, and `desktop doctor`
  had no Windows full-check support. For UAC or other desktop-token evidence,
  stop and record this as a Crabbox managed-input blocker after one marker probe;
  never replace that evidence with SSH.
- Never kill a guest workspace-owner/sync process or remove its marker without
  explicit authorization for the exact PID/marker. A partial archive can be
  bypassed with per-file transfer; do not delete it merely to retry.

For stateful browser UAT only, route to `crabbox-browser-profile-persistence`.
Automated fake-OAuth validation starts with a fresh profile.
