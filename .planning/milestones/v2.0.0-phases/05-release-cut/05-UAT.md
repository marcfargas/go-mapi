# Phase 5 UAT: v2.0.0 Manual End-to-End Verification (REL-06)

**Tester:** Marc Fargas
**Environment:** [marcwin / Windows Sandbox — circle one]
**Date:** [YYYY-MM-DD]
**Installer URL tested:** https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe
**Installer SHA256:** [run `(Get-FileHash go-mapi-setup.exe -Algorithm SHA256).Hash` and paste here]
**Browser used:** [Chrome / Edge / Chromium / Brave / Vivaldi — circle one]
**Target Gmail account:** [e.g. marc@example.com — just for your own record]

---

## Pre-conditions

- [ ] REL-05 complete: `installer-release.yml` run for `v2.0.0` reached `conclusion: success`
- [ ] `curl -IL https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` returned HTTP 200 with a non-empty `Content-Length`
- [ ] The UAT host is a CLEAN state: go-mapi not currently installed, no stale registry under `HKLM\SOFTWARE\Clients\Mail\go-mapi`, no files under `%ProgramFiles%\go-mapi\` or `%ProgramData%\go-mapi\`
- [ ] A Gmail or Google Workspace account is signed in to the browser being used

---

## UAT Session

### Step 1 — Download

Visit `https://github.com/marcfargas/go-mapi/releases/latest` in the browser. Click the `go-mapi-setup.exe` asset.

- [ ] Download completes without errors
- [ ] Downloaded file size matches `content-length` from the `curl -IL` preflight
- [ ] **Observed file size:** [bytes]

### Step 2 — SmartScreen walkthrough (unsigned fallback — D-01)

Double-click `go-mapi-setup.exe` from the Downloads folder.

- [ ] **"Windows protected your PC"** dialog appears (expected; v2.0.0 ships unsigned)
- [ ] Click **More info** — publisher line appears ("Unknown publisher")
- [ ] Click **Run anyway** — dialog dismisses
- [ ] IF the dialog does NOT appear: note below (possibly Defender already saw the file; not a blocker, but record it)
- [ ] **Notes:** [free text]

### Step 3 — UAC + installer wizard

- [ ] Exactly ONE UAC prompt appears (per INST-04)
- [ ] Clicking **Yes** launches the Inno Setup wizard
- [ ] Wizard completes without error dialogs
- [ ] Final "Installation completed successfully" screen appears
- [ ] **Wall-clock time from launch to wizard completion:** [seconds]

### Step 4 — Post-install filesystem state

Open PowerShell (non-elevated is fine):

```powershell
Test-Path 'C:\Program Files\go-mapi\go-mapi.dll'
Test-Path 'C:\Program Files\go-mapi\go-mapi-host.exe'
Test-Path 'C:\ProgramData\go-mapi\com.gomapi.host.json'
Test-Path 'C:\ProgramData\go-mapi\uninst\previous-mail-client.json'
```

- [ ] All four paths return `True`
- [ ] **Notes:** [free text if any return False]

### Step 5 — Post-install registry state

```powershell
Test-Path 'HKLM:\SOFTWARE\Clients\Mail\go-mapi'
Test-Path 'HKLM:\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host'
Test-Path 'HKLM:\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host'
Test-Path 'HKLM:\SOFTWARE\Chromium\NativeMessagingHosts\com.gomapi.host'
Test-Path 'HKLM:\SOFTWARE\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.gomapi.host'
Test-Path 'HKLM:\SOFTWARE\Vivaldi\NativeMessagingHosts\com.gomapi.host'
```

- [ ] All six paths return `True`
- [ ] `(Get-ItemProperty 'HKLM:\SOFTWARE\Clients\Mail').'(Default)'` returns `go-mapi`
- [ ] **Notes:** [free text]

### Step 6 — Load the browser extension

From the browser chosen at the top of this file:

1. Open `chrome://extensions` (or the equivalent)
2. Enable **Developer mode**
3. Click **Load unpacked** and select the `dist/` folder from the unpacked release ZIP (or install from the Chrome Web Store listing if it's live)
4. Click the go-mapi extension icon in the toolbar to open the popup

- [ ] Extension loads without errors in `chrome://extensions`
- [ ] Popup opens when clicking the toolbar icon
- [ ] **Initial popup state:** [MISSING / PROBING / READY — circle one]

### Step 7 — Host-state transition + success toast (EXT-06 / PHASE-4-FINDING-01)

This step verifies the MISSING -> READY transition and the one-time success toast that PHASE-4-FINDING-01 fixed at the end of Phase 4.

**If the initial popup state in Step 6 was READY** — go-mapi was already discovered on first popup open. Skip to Step 8 and note that the toast could not be observed on this run (the toast only fires on the live MISSING -> READY edge). To exercise this path, close the browser, uninstall go-mapi, re-open the browser first, then re-install — but this is optional.

**If the initial popup state was MISSING or PROBING:**

- [ ] Within ~6 seconds (one reconnect alarm cycle), the popup transitions to READY
- [ ] The `InstallPrompt` banner disappears
- [ ] A one-time **"go-mapi is installed"** success toast appears
- [ ] Closing and reopening the popup does NOT show the toast again (one-time only via `hasShownInstalledToast` latch)
- [ ] **Notes:** [free text]

### Step 8 — Real MAPI trigger (the shipping gate)

1. Open Notepad (or any Win32 app with a "Send to Mail recipient" shell integration).
2. Type some placeholder text.
3. Save to a file so File Explorer knows about it.
4. In File Explorer, right-click the saved file -> **Send to** -> **Mail recipient**.

**Expected result:** Within a second or two, the go-mapi extension popup (if open) shows a new email entry. If the popup is closed, the extension badge updates to show the queue count.

- [ ] Right-click -> Send to -> Mail recipient does NOT show an error dialog
- [ ] The extension popup / badge reflects the new email within ~2 seconds
- [ ] Click the email in the popup to preview it
- [ ] The preview shows the attached file(s) as a draft body with attachment metadata
- [ ] **Notes:** [free text]

### Step 9 — Gmail draft creation

Click **Save as Draft** in the extension popup.

- [ ] The "Save as Draft" action succeeds without showing an error toast
- [ ] Open `https://mail.google.com/mail/u/0/#drafts` in the same browser
- [ ] A new draft appears at the top of the Drafts list, authored from the go-mapi-triggered action
- [ ] The draft contains the attachment(s) from the file that was right-clicked
- [ ] **Gmail draft ID (from URL after clicking the draft):** [optional, for record-keeping]

**This step is the v2.0.0 shipping gate.** If the draft appears in Gmail, the end-to-end flow works and Phase 5 passes UAT.

### Step 10 — Uninstall + cleanup

Windows **Settings -> Apps -> Installed apps -> go-mapi -> Uninstall**.

- [ ] Uninstall wizard launches with one UAC prompt
- [ ] Uninstall completes without error dialogs

After uninstall:

```powershell
Test-Path 'C:\Program Files\go-mapi\go-mapi.dll'        # expect False
Test-Path 'C:\ProgramData\go-mapi\com.gomapi.host.json' # expect False
Test-Path 'HKLM:\SOFTWARE\Clients\Mail\go-mapi'         # expect False
Test-Path 'HKLM:\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host'  # expect False
```

- [ ] All four checks return `False`
- [ ] Previous default Mail client (if any) restored from the backup file (INST-05/INST-06)
- [ ] **Notes:** [free text]

---

## UAT Disposition

Select ONE:

- [ ] **PASSED** — all steps green, Gmail draft created, clean uninstall. v2.0.0 ships.
- [ ] **PASSED WITH NOTES** — all critical steps green, minor deviations documented above but not blocking. v2.0.0 ships. List deviations:
  - [free text]
- [ ] **FAILED** — a critical step failed. A fix is required before v2.0.0 ships. Next action:
  - [ ] Fix on develop, cut new `v2.0.1` tag (per D-05, NEVER re-use `v2.0.0`), re-run `installer-release.yml`, re-run this UAT against the new installer.
  - [ ] Failure details: [free text]

**Ship decision:** [SHIP / BLOCK — circle one]
**Signed off by:** Marc Fargas
**Signed off at:** [timestamp]

---

*This file is the REL-06 authoritative record. Commit it to `develop` before running REL-07.*
