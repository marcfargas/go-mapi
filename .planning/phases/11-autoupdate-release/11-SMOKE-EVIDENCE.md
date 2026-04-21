# Phase 11 Clean-Machine Smoke Evidence Ledger

**Status:** PENDING — awaiting the human-verify checkpoint from plan 11-05.

This file is the canonical artifact ledger for the Phase 11 pre-GA smoke rehearsal.
It records, for each checklist step in `11-SMOKE-CHECKLIST.md`, the evidence that
was captured and the pass/fail verdict. The file is part of the repo; the
underlying screenshots/videos live under
`tests/sandbox/phase11/evidence-<timestamp>/` on the host and are gitignored.

## Run metadata

| Field | Value |
|-------|-------|
| Run ID (evidence dir timestamp) | `evidence-YYYYMMDD-HHMMSS` (fill in) |
| Installer source | `workflow_dispatch dry-run artifact` \| `releases/latest/download/go-mapi-setup.exe` (circle one) |
| Installer SHA256 | (fill in from `evidence-manifest.json`) |
| Installer version string | `<major>.<minor>.<patch>` (fill in from Wails info dialog or logs) |
| Sandbox host OS build | (fill in — e.g. Windows 11 Pro 26200.xxxx) |
| Operator | Marc Fargas |
| Started at (UTC) | (fill in) |
| Ended at (UTC) | (fill in) |
| Verdict | PASS \| FAIL — (fill in) |

## Step-by-step evidence

### Step 1 — install (automated)

- Screenshot(s): `screenshots/01-pre-install.png`, `screenshots/02-post-install.png`
- Log: `logs/harness.log`, `logs/installer-stdout.log`
- Installer exit code: `0` (expected)
- Verdict: PASS / FAIL — (fill in)
- Notes: (fill in — any warnings, AV interference, download timing)

### Step 2 — app launch

- Screenshot: `screenshots/03-app-launched.png`
- Tray icon visible: YES / NO (fill in)
- Sign-in screen rendered: YES / NO (fill in)
- Verdict: PASS / FAIL
- Notes:

### Step 3 — sign in (OAuth manual tail)

- Screenshot: `screenshots/04-signed-in.png`
- Google consent screen appeared: YES / NO
- Loopback redirect completed without timeout: YES / NO
- Signed-in header shows expected account: YES / NO
- Re-auth banner suppressed: YES / NO
- Verdict: PASS / FAIL
- Notes: (fill in — OAuth is the slowest manual step; record any consent
  screen oddities, blocked-app warnings, SmartScreen intervention, etc.)

### Step 4 — MAPI trigger

- Screenshot: `screenshots/05-mapi-sendto.png`
- Trigger method: Notepad `Send to → Mail recipient`
- JSON file written to `%TEMP%\go-mapi\`: YES / NO
  (proved by `logs/harness.log` or the `TEMP\go-mapi` snapshot in the
   evidence manifest)
- Verdict: PASS / FAIL
- Notes:

### Step 5 — queue row

- Screenshot: `screenshots/06-queue-row.png`
- Queue row appears within 5 seconds of MAPI trigger: YES / NO
- Subject matches sent file: YES / NO
- Row is clickable / opens detail: YES / NO
- Verdict: PASS / FAIL
- Notes:

### Step 6 — Gmail draft

- Screenshots: `screenshots/07-draft-created.png`, `screenshots/08-draft-in-gmail.png`
- `Create draft` button worked: YES / NO
- Queue row cleared after draft creation: YES / NO
- Draft visible in Gmail `/mail/u/0/#drafts`: YES / NO
- Draft subject + body match: YES / NO
- Verdict: PASS / FAIL
- Notes: (fill in — redact account email before committing screenshots
  per CLAUDE.md privacy rule)

### Step 7 — uninstall

- Screenshot: `screenshots/09-post-uninstall.png`
- Uninstall exit code: `0` (expected)
- Install dir removed: YES / NO
- MAPI handler key removed: YES / NO
- `%APPDATA%\go-mapi` removed: YES / NO
- Credential Manager scrubbed (`go-mapi:oauth-tokens` gone): YES / NO
- Firewall rule removed: YES / NO
- Start Menu shortcut removed: YES / NO
- Verdict: PASS / FAIL
- Notes:

### Step 8 — evidence collection

- `evidence-manifest.json` present: YES / NO
- All expected files listed (screenshots, logs, harness metadata): YES / NO
- Verdict: PASS / FAIL

## Video capture (optional per D-15)

| Clip | Path | Range | Covers |
|------|------|-------|--------|
| main | `video/phase11-smoke.mp4` | 00:00 - xx:xx | full run |
| oauth | `video/phase11-oauth.mp4` | 00:00 - xx:xx | sign-in tail |

## Final verdict

- [ ] Every step above has PASS recorded.
- [ ] Every listed screenshot / log file exists in the evidence dir.
- [ ] `evidence-manifest.json` SHA256 entries match what is on disk.

Signing off this ledger means: one full install → sign in → MAPI trigger →
queue row → Gmail draft → uninstall journey worked on a clean machine (D-16),
and the GA tag push for plan 11-04 is unblocked.

Signed-off by: (fill in) on (date).
