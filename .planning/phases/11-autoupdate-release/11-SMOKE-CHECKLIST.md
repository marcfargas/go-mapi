# Phase 11 Clean-Machine Smoke Checklist

**Purpose:** REL-06 gate — prove the full v3.0 user journey works once on a
reproducible clean Windows environment before tagging the GA release.

**Target environment:** Windows Sandbox launched from
`tests/sandbox/phase11/go-mapi-phase11.wsb`, or any equivalent disposable
clean Windows 10/11 VM (D-13). The automation assumes the Windows Sandbox
path; for another VM, run the same scripts manually.

**Time budget:** roughly 15 minutes of wall-clock; roughly 3 minutes of
active human interaction (OAuth consent + MAPI trigger + draft verify).

**Evidence rule:** every numbered step must produce *either* a screenshot /
video clip *or* a text note in `11-SMOKE-EVIDENCE.md`. A "pass" without any
evidence does not close REL-06.

---

## 0. Pre-flight (on the host)

- [ ] Check out the tag or branch under test.
- [ ] Pick an installer source:
  - **Option A — release candidate via `workflow_dispatch` dry-run artifact:**
    download `go-mapi-setup.exe` from the most recent `workflow_dispatch`
    run of `installer-release.yml`, place it at
    `tests/sandbox/phase11/installer/go-mapi-setup.exe`.
  - **Option B — published stable release:** leave the staging folder empty;
    the harness will download from
    `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`.
- [ ] Optional: start screen-recording software on the host pointed at the
      sandbox window (OBS, ShareX, Windows Game Bar — free tools all fine).
      Save the video output to `tests/sandbox/phase11/evidence-<timestamp>/video/`
      once available.
- [ ] Double-click `go-mapi-phase11.wsb` to launch the sandbox. Windows
      Sandbox auto-runs `Run-Phase11Smoke.ps1` as the logon command.

## 1. Install (mostly automated)

- [ ] Sandbox logs in; PowerShell console appears.
- [ ] `Run-Phase11Smoke.ps1` prints the evidence directory path — note it
      (e.g. `C:\phase11\evidence-20260421-143012`).
- [ ] Installer exits 0 (automated assert).
- [ ] Post-install screenshot `02-post-install.png` is written.
- **Evidence:** screenshots `01-pre-install.png`, `02-post-install.png`,
  plus `logs\harness.log`.

## 2. App launch

- [ ] Start Menu shortcut `go-mapi.lnk` exists and is launched by the harness.
- [ ] The Wails window renders the **sign-in screen** (welcome + Google button).
- [ ] Tray icon appears in the system tray.
- **Evidence:** screenshot `03-app-launched.png`, plus a manual screenshot of
  the tray icon area.

## 3. Sign in (manual — OAuth consent cannot be automated)

- [ ] Click `Sign in with Google` in the sign-in screen.
- [ ] Default browser opens Google consent for `gmail.compose` and `gmail.send`.
- [ ] Authenticate with the test Gmail account. (Never use a personal primary
      Gmail account — use a disposable test account.)
- [ ] Consent loopback returns; the app shows the signed-in header (name + email).
- [ ] Re-auth banner is NOT shown.
- **Evidence:** manual screenshot `04-signed-in.png` of the signed-in header.

## 4. MAPI trigger (manual — needs a real Windows app doing a MAPI send)

- [ ] Open Notepad inside the sandbox.
- [ ] Type a short body (`Phase 11 smoke test`) and save as
      `C:\Users\WDAGUtilityAccount\Desktop\smoke.txt`.
- [ ] Right-click the file → `Send to` → `Mail recipient`.
- [ ] Windows invokes the MAPI handler (`go-mapi.dll`), which writes JSON to
      `%TEMP%\go-mapi\`.
- **Evidence:** manual screenshot `05-mapi-sendto.png` of the Send to menu.

## 5. Queue row

- [ ] Within 2-3 seconds, the Wails window shows a queued email row
      corresponding to the `smoke.txt` send.
- [ ] Subject reads `smoke` (or similar — depending on how the legacy MAPI
      client filled the subject field).
- **Evidence:** manual screenshot `06-queue-row.png` of the queue view.

## 6. Gmail draft

- [ ] Click `Create draft` on the queue row.
- [ ] The row disappears (processed and deleted from `%TEMP%\go-mapi\`).
- [ ] Open `https://mail.google.com/mail/u/0/#drafts` in the sandbox browser.
- [ ] The new draft exists with the expected subject + body.
- **Evidence:** manual screenshots `07-draft-created.png` (app view) and
  `08-draft-in-gmail.png` (Gmail drafts view). Redact or crop the account
  email address in the second screenshot per D-15 + CLAUDE.md privacy rule.

## 7. Uninstall (mostly automated)

- [ ] Close the Wails window and right-click tray icon → `Quit`.
- [ ] Inside the sandbox, open an elevated PowerShell and run:
      `& 'C:\Program Files\go-mapi\uninstall.exe' /S`
- [ ] Confirm exit code is 0.
- [ ] Verify clean removal:
      - `Test-Path 'C:\Program Files\go-mapi'` → False (or empty dir)
      - `Test-Path 'HKLM:\SOFTWARE\Clients\Mail\go-mapi'` → False
      - `Test-Path "$env:APPDATA\go-mapi"` → False
      - `cmdkey /list:go-mapi:oauth-tokens` → no matching entries
      - `Get-NetFirewallRule -DisplayName 'go-mapi OAuth loopback'` → empty
      - Start Menu shortcut gone.
- **Evidence:** manual screenshot `09-post-uninstall.png` of the PowerShell
  console with the checks above.

## 8. Collect evidence (automated)

- [ ] Run `C:\phase11\Collect-Phase11Evidence.ps1` — gathers `app.log`,
      installer/uninstaller logs, the TEMP MAPI JSON staging state, and
      writes `evidence-manifest.json` with SHA256 hashes.
- **Evidence:** `evidence-manifest.json` under the evidence dir.

## 9. Fill the evidence ledger (on the host)

- [ ] Close the sandbox. The mapped folder
      `tests/sandbox/phase11/evidence-<timestamp>/` persists on the host.
- [ ] Open `11-SMOKE-EVIDENCE.md` and fill every step with: screenshot
      filename, video timestamp range (if recorded), pass/fail verdict, and
      free-form notes for anything unexpected.
- [ ] Commit the filled `11-SMOKE-EVIDENCE.md` (evidence files themselves are
      gitignored under `tests/sandbox/phase11/evidence-*/`).

## 10. Resume signal

- [ ] If all steps passed, reply to the GSD executor with `approved` so the
      orchestrator can continue toward the GA tag push in plan `11-04`.
- [ ] If any step failed, capture the failing screenshot + the app log,
      record the outcome in `11-SMOKE-EVIDENCE.md`, and reply with the
      failing step number plus a short description — DO NOT reply `approved`.
