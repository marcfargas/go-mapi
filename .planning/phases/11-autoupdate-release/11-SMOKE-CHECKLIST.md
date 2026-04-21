# Phase 11 clean-machine smoke — human checklist

This checklist is the **short manual tail** (D-14) left after `Run-Phase11Smoke.ps1`
automates everything it can. On a green path there are exactly **three** moments
where the script waits for you. Everything else (install, launch, mailto trigger,
queue-file detection, uninstall, cleanliness check, evidence ledger) is scripted.

## Pre-flight (host, before launching sandbox)

1. Verify the v3.0 RC installer is staged:

   ```pwsh
   Test-Path C:\dev\go-mapi\tests\sandbox\phase11\installer\go-mapi-setup.exe
   ```

   If missing, build one:

   ```pwsh
   pwsh -ExecutionPolicy Bypass -File C:\dev\go-mapi\build-rc.ps1
   ```

   (requires NSIS installed locally; `scoop install nsis` or `choco install nsis`)

2. (Optional) Start a screen recorder pointed at the sandbox window.

## Launch sandbox

Double-click `C:\dev\go-mapi\tests\sandbox\phase11\go-mapi-phase11.wsb`.

The logon command auto-runs `Run-Phase11Smoke.ps1`, which will:

- unblock mapped scripts
- create `C:\phase11\evidence-<timestamp>\`
- take pre-install screenshot
- silent-install the RC (`/S`)
- take post-install screenshot
- launch the app from the Start Menu
- pause and wait for you (prompt 1 below)

## Manual tail (inside sandbox) — 3 prompts

### Prompt 1 — OAuth sign-in

The app opens its own browser window for Google OAuth consent. Complete the
consent flow in that window. Once the app shows the signed-in header, press
**ENTER** in the PowerShell console. The script polls `app.log` for
`oauth: signed in as` — if it never sees that line within 5 min, it aborts
with `oauth = FAIL`.

### Prompt 2 — Create draft click

After prompt 1, the script auto-triggers a `mailto:` send, which routes through
the newly-installed go-mapi MAPI handler and drops a JSON into `%TEMP%\go-mapi\`.
The go-mapi window will show a new queue row.

**Click "Create draft" on the queue row.** Then press **ENTER** in the
PowerShell console. The script polls `app.log` for `gmail: draft created id=` —
2-min budget.

### Prompt 3 — Gmail glance (y/n)

Open Gmail in your browser. Confirm the draft appeared in Drafts. The script
asks `[y]/n` — type `y` on success, `n` if the draft is missing.

## Post-script (inside sandbox)

The script then auto-uninstalls, verifies cleanliness, and writes
`<EvidenceDir>\EVIDENCE.md` with PASS/FAIL per step plus screenshot refs.

**Leave the sandbox running** until you've read the final console output.

## Close sandbox (host)

The mapped evidence folder persists at:

```
C:\dev\go-mapi\tests\sandbox\phase11\evidence-<timestamp>\
```

## Fill ledger (host)

Copy the contents of `<EvidenceDir>\EVIDENCE.md` into
`.planning/phases/11-autoupdate-release/11-SMOKE-EVIDENCE.md`, commit the
ledger only (screenshots + app.log stay gitignored under
`tests/sandbox/phase11/evidence-*/`).

## Resume signal

Reply `approved` to the orchestrator once the ledger shows `Overall: PASS`.
If any step shows `FAIL`, describe which and paste the relevant screenshot
filename — do not reply `approved` on a partial pass.
