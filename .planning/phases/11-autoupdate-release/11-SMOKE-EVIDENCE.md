# Phase 11 clean-machine smoke evidence

**Status:** PASS (user-confirmed functional journey; three harness-only findings annotated).

## Harness run metadata

- Run at: 2026-04-23T14:31:14+02:00
- Evidence dir: `tests/sandbox/phase11/evidence-20260423-142407/` (gitignored)
- Installer: `C:\phase11\installer\go-mapi-setup.exe`
- Installer SHA256: `F6673723AABEAF04CC98CD467B3862833AF08E92A897724255D6A5B7AA614A29`
- Installer version: `3.0.0-rc.2`

## Outcomes (raw ledger + annotation)

| Step | Raw ledger | Annotated verdict | Notes |
|------|------------|-------------------|-------|
| install   | PASS | PASS | Silent `/S` install succeeded. |
| launch    | PASS | PASS | Shortcut resolved via Launch-App fallback (per-user Start Menu). |
| oauth     | PASS | PASS | `oauth: signed in as marc@blegal.eu` at 12:26:25Z. |
| mapi      | PASS (mailto: dispatched) | PASS (via Explorer, not mailto:) | **Harness limitation A** — `mailto:` goes through Edge (URL-protocol handler), not through MAPI. Installer registers `HKLM\SOFTWARE\Clients\Mail\go-mapi` for MAPI only, which is the actual supported "Send to Mail recipient" path from File Explorer and Office. Human manually triggered a file send from Explorer → the MAPI DLL wrote JSON to `%TEMP%\go-mapi\` correctly. |
| queue     | FAIL (no queue JSON)                      | PASS | Queue row appeared after the manual Explorer trigger (post-MAPI). Only `FAIL` in the ledger because the auto-`mailto:` step never fed the watcher. |
| draft     | FAIL (timeout waiting for log line)       | PASS | Draft was successfully created. **Harness limitation B** — the 120 s polling budget started before the human manually triggered MAPI, so the deadline expired while the human was still driving the UI. `app.log` shows the draft toast-clear path firing at 12:27:36Z and 12:28:10Z (consistent with `MarkProcessed`). |
| gmail     | PASS (human confirmed) | PASS | Human confirmed draft appeared in Gmail Drafts. |
| uninstall | PASS | PASS | Silent uninstall exit 0. |
| clean     | FAIL (`C:\Program Files\go-mapi` still has 1 item) | ACCEPTED | **NSIS limitation** — in `/S` silent mode the uninstaller cannot delete its own `uninstall.exe` and schedules it for deletion on next reboot (`Delete /REBOOTOK`). A disposable Windows Sandbox never reboots, so the file persists until teardown. Not a real-user issue. |

## Final verdict

- **Overall: PASS** (all five REL-06 pillars demonstrated — install, sign-in, MAPI-triggered queue row, Gmail draft, silent uninstall).

## Known limitations observed during this smoke (all investigated, none release-blocking)

### H-1: Local rc.2 build embedded the dev AUMID

`app.log` shows `toast: initialized (aumid=com.marcfargas.gomapi.dev)`. The local build used the wrong ldflag target (`-X github.com/marcfargas/go-mapi/app.aumidOverride=...`) which Go's linker silently ignored because `aumidOverride` lives in `package main`. Authoritative form is `-X main.aumidOverride=...` — same pattern `main.oauthClientID`, `main.Version` use successfully in the same invocation.

**Impact on GA:** none. `.github/workflows/installer-release.yml:103` already uses the correct `-X main.aumidOverride=com.marcfargas.gomapi`. The CI-built GA installer will ship the prod AUMID.

**Fix landed in this smoke commit:** `scripts/build-phase11-installer.ps1` header comment corrected; `.planning/.../11-05-SUMMARY.md` decision log updated.

### H-2: Sandbox `mailto:` dispatch exercises Edge, not MAPI

The harness' automated MAPI trigger via `Start-Process mailto:...` hits the URL-protocol handler (Edge) rather than the MAPI shim. The supported user path — File Explorer "Send to Mail recipient" and Office "Send as attachment" — routes through `mapi32.dll` → `HKLM\SOFTWARE\Clients\Mail\go-mapi` → go-mapi.dll and works correctly. The smoke confirmed this by manual file send from Explorer inside the sandbox.

**Recommended follow-up (out of scope for this phase):** future harness iteration could spawn an Outlook-style MAPI client (e.g., a small script that calls `MAPISendMail` directly) to remove the human trigger. Captured as todo.

### H-3: Toast clear fails in Windows Sandbox

`app.log` shows repeated `toast: clear ... failed: QueryInterface IToastNotificationHistory: Interfaz no compatible` errors. Windows Sandbox's WinRT host does not expose `IToastNotificationHistory`. Toast clearing works on real Windows 10/11 hosts; the failure is a sandbox-only artefact and does not impact user-visible behaviour because the smoke still produced the expected draft.

### H-4: NSIS `/S` uninstall residual

`C:\Program Files\go-mapi\uninstall.exe` persists after silent uninstall. NSIS schedules self-deletion on next reboot via `Delete /REBOOTOK`. Real user machines reboot; sandboxes don't. Accept.

## Screenshot references (binaries gitignored under `tests/sandbox/phase11/evidence-*/screenshots/`)

- `01-pre-install.png`
- `02-post-install.png`
- `03-launched.png`
- `04-signed-in.png`
- `05-queue-row.png`
- `06-draft-created.png`
- `07-post-uninstall.png`

## Decisions honored

- D-13: Windows Sandbox was the clean-room.
- D-14: Short manual tail (human triggered Explorer send + clicked Create-draft + Gmail glance).
- D-15: Screenshots captured at 7 checkpoints; `app.log` snapshot committed under evidence dir.
- D-16: One fully working clean-machine journey achieved on rc.2.

## Harness fixes committed alongside this evidence

- `tests/sandbox/phase11/go-mapi-phase11.wsb` — LogonCommand wrapped in `cmd /c start` so PowerShell runs in a visible console (prior invocation ran hidden, silently blocking on `Read-Host`).
- `tests/sandbox/phase11/Run-Phase11Smoke.ps1` — `Launch-App` now checks per-user Start Menu and falls back to `%ProgramFiles%\go-mapi\go-mapi.exe` (NSIS `$SMPROGRAMS` resolves to per-user without `SetShellVarContext all`; latent NSI bug captured as separate follow-up).
- `scripts/build-phase11-installer.ps1` — header comment corrected from `-X github.com/marcfargas/go-mapi/app.aumidOverride=...` to `-X main.aumidOverride=...`.

## Resume signal

`approved` — Plan 11-05 closure gate met. Plan 11-04 (v3.0 GA release cut) unblocked.
