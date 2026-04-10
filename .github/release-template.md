go-mapi is a Free Software bridge that routes the Windows "Send to Mail recipient" action to Gmail as drafts, so legacy desktop applications can compose email through Gmail without Outlook.

## Download

Direct download:

<https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe>

This link always points at the latest stable release.

## Installation

1. Download `go-mapi-setup.exe` (link above).
2. Run it. Windows will show a single UAC prompt — click **Yes** to allow
   the installer to register go-mapi as the default Mail client.
3. Follow the wizard to finish. That's it — no terminal, no toolchain.

After the installer completes, open Chrome, Edge, Chromium, Brave, or
Vivaldi and pin the go-mapi extension (install it from the Chrome Web
Store first if you haven't already). Any "Send to Mail recipient" action
from a Windows app now appears in the extension popup as a Gmail draft.

## If Windows SmartScreen blocks the installer

You may see a blue "Windows protected your PC" dialog when you run the
installer. This happens for two reasons:

- **New unsigned builds.** While the project's SignPath Foundation
  application is in review, go-mapi ships unsigned. The installer is
  safe — the source is public and every release builds from a
  reproducible GitHub Actions workflow — but SmartScreen does not know
  that yet.
- **New signed builds.** Even after code signing lands, SmartScreen may
  still warn on the first few releases until Microsoft's reputation
  engine learns the certificate.

To continue the install:

1. Click the small **More info** link in the SmartScreen dialog.
2. A **Run anyway** button appears below the publisher line. Click it.
3. Proceed with the normal UAC prompt and wizard.

This is a one-time click-through. Subsequent runs of the same file do
not show the dialog again.

## What the installer does

- Copies `go-mapi.dll` and `go-mapi-host.exe` to `C:\Program Files\go-mapi\`.
- Registers go-mapi as the Windows default Mail client under
  `HKLM\SOFTWARE\Clients\Mail\go-mapi`. Your previous default Mail
  client (if any) is backed up to
  `C:\ProgramData\go-mapi\uninst\previous-mail-client.json` so uninstall
  can restore it.
- Writes a single shared native-messaging manifest at
  `C:\ProgramData\go-mapi\com.gomapi.host.json` and registers it with
  five Chromium-family browsers (Chrome, Edge, Chromium, Brave, Vivaldi)
  under `HKLM`, so any of them can talk to the host without per-user
  setup.

## Uninstall

Use **Settings → Apps → Installed apps → go-mapi → Uninstall**, or run
the uninstaller directly at `C:\Program Files\go-mapi\unins000.exe`.

Uninstall removes every file and registry entry the installer wrote and
restores the previous default Mail client from the backup file.

## Privacy

go-mapi is privacy-first by design:

- No telemetry of any kind.
- No long-term storage of message content — transient JSON files under
  `%TEMP%\go-mapi\` are deleted immediately after you click Save as
  Draft or Delete.
- No network calls except to the Gmail API, on your behalf, to create
  the draft when you click Save as Draft.
- No crash reporting, no update-check beacons, no background service.

## Support

Issue tracker: <https://github.com/marcfargas/go-mapi/issues>

Source, license (LGPL-3.0-or-later), and project docs:
<https://github.com/marcfargas/go-mapi>

---
