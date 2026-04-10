# go-mapi Installer (Inno Setup 6)

This directory contains the Inno Setup script that builds the single-file
Windows installer `go-mapi-setup.exe`.

## Files

- `go-mapi.iss` — Inno Setup 6 source script. Compiled with `iscc.exe`.
- `tests/installer.Tests.ps1` — Pester 5 smoke test that runs a full
  silent install → verify → silent uninstall → verify cycle on a
  fresh Windows host. Invoked from
  `.github/workflows/installer-smoke.yml`.
- `dist/` — compile output (gitignored; created by `iscc.exe`).

## Build (local)

Prerequisites:

1. Inno Setup 6 installed. `iscc.exe` on PATH, or use the default
   Chocolatey path `C:\Program Files (x86)\Inno Setup 6\iscc.exe`.
2. Payload binaries built first:
   - `npm run build:interceptor` → `src/interceptor/build/bin/go-mapi.dll`
   - `npm run build:native-host`  → `src/native-host/build/go-mapi-host.exe`

Then from the repo root:

```powershell
& "C:\Program Files (x86)\Inno Setup 6\iscc.exe" /DGOMAPIVersion=1.0.0 src\installer\go-mapi.iss
```

The `/DGOMAPIVersion=<semver>` flag stamps the version into `AppVersion`.
Without it, the installer builds as `0.0.0-dev`.

Output: `src\installer\dist\go-mapi-setup.exe`.

## Silent install / uninstall (for testing)

```powershell
# Silent install with logging
.\go-mapi-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=install.log

# Silent uninstall
& "$env:ProgramFiles\go-mapi\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
```

## What the installer does

On install (single UAC prompt):

1. Copies `go-mapi.dll` and `go-mapi-host.exe` to `%ProgramFiles%\go-mapi\`.
2. Backs up the current `HKLM\SOFTWARE\Clients\Mail\(Default)` value to
   `%ProgramData%\go-mapi\uninst\previous-mail-client.json` (only if a
   previous client exists and no backup is already present, so upgrade
   reinstalls preserve the original backup).
3. Registers the MAPI handler under
   `HKLM\SOFTWARE\Clients\Mail\go-mapi` with
   `DLLPath = %ProgramFiles%\go-mapi\go-mapi.dll` and sets go-mapi as the
   active default Mail client.
4. Renders the native-messaging manifest from
   `src/native-host/manifests/com.gomapi.host.chrome.json.tmpl`
   (embedded in the installer via `dontcopy`) to
   `%ProgramData%\go-mapi\com.gomapi.host.json`, substituting
   `{{HOST_PATH}}` with the absolute host binary path and
   `{{EXTENSION_ID}}` with the `GO_MAPI_EXTENSION_ID` constant from the
   `.iss` `[Code]` section.
5. Writes five HKLM native-messaging registry trees pointing at the
   shared manifest: Chrome, Chromium, Edge, Brave, Vivaldi.

On uninstall:

1. Removes the five browser registry trees (via `uninsdeletekey`).
2. Removes the MAPI handler key.
3. Restores the previous default Mail client from the backup JSON; falls
   back to well-known clients (`Microsoft Outlook`, `Outlook`,
   `Windows Mail`) or clears the value if nothing else exists.
4. Deletes the shared manifest, the backup JSON, and the
   `%ProgramData%\go-mapi\` directory (if empty).
5. Best-effort deletes `%TEMP%\go-mapi\` (the watcher's drop zone).
6. Removes the DLL and host binary and the `%ProgramFiles%\go-mapi\`
   directory.

## Manifest schema

The `.tmpl` file at
`src/native-host/manifests/com.gomapi.host.chrome.json.tmpl` is the
single source of truth for the native-messaging manifest schema. Both
this installer and `scripts/install.ps1` render the same template. Do
not duplicate the schema here.

## Extension ID

The `GO_MAPI_EXTENSION_ID` constant near the top of the `[Code]`
section of `go-mapi.iss` is the Chrome Web Store extension ID used
as the `allowed_origins` value. It defaults to
`PLACEHOLDER_EXTENSION_ID_32CHR` until the Chrome Web Store listing
is published. When the listing goes live:

1. Edit `go-mapi.iss` — change `GO_MAPI_EXTENSION_ID`.
2. Edit `scripts/install.ps1` — update the corresponding placeholder.
3. Rebuild the installer.

## Smoke test

The Pester 5 smoke test at `tests/installer.Tests.ps1` runs on every
PR touching the installer sources via
`.github/workflows/installer-smoke.yml`. Run locally with:

```powershell
Invoke-Pester -Path tests/installer.Tests.ps1 -Output Detailed
```

Note: the smoke test requires admin rights (silent install writes
to `%ProgramFiles%`) and will install and uninstall go-mapi on your
machine. Use a throwaway VM for local runs.
