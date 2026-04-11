# go-mapi

**The MAPI-to-Gmail bridge you always wanted.**

## Overview

[MAPI](https://en.wikipedia.org/wiki/MAPI) (Messaging Application Programming Interface) is a Microsoft Windows API that allows programs to become email-aware. It enables the "Send by Email" feature found in many Windows applications - from right-clicking a file in Explorer to printing to PDF and emailing it.

**Gmail and Google Workspace have no native MAPI support.** Despite Google Workspace being a major enterprise email solution, there has never been an official MAPI-to-Gmail bridge.

A few third-party tools have filled this gap over the years. The most notable, [Affixa](https://help.affixa.com/article/100-sunsetting-and-retirement-of-affixa), recently announced its shutdown - leaving Google Workspace users without a way to use "Send by Email" functionality.

**go-mapi** is the open-source replacement.

## Status

**v2.0.0** — First shipped milestone with a single-click Windows installer and a full Chromium-family browser extension. See [Installation](#installation) for the end-user flow.

| Component | Status |
|-----------|--------|
| MAPI interception (ANSI + Unicode) | ✅ Stable |
| Native messaging bridge | ✅ Stable |
| Browser extension (popup + notifications) | ✅ Stable |
| Gmail draft creation (with attachments) | ✅ Stable |
| UTF-8 / codepage encoding | ✅ Stable |
| Single-click Windows installer (Inno Setup 6) | ✅ v2.0.0 |
| Chrome / Edge / Chromium / Brave / Vivaldi | ✅ v2.0.0 |
| Windows Sandbox local repro | ✅ v2.0.0 (`tests/sandbox/`) |

## Architecture

go-mapi uses a three-component architecture optimized for enterprise deployment:

```
┌─────────────────────┐                      ┌─────────────────────┐
│   Windows App       │                      │  Browser Extension  │
│   (Explorer, etc.)  │                      │  (Chrome / Edge)    │
│         │           │                      │         │           │
│    MAPISendMail()   │                      │   React Popup UI    │
│         ▼           │                      │         │           │
│  ┌─────────────┐    │   %TEMP%\go-mapi\    │   ┌───────────┐     │
│  │ go-mapi.dll │────┼──────────────────────┤   │ Gmail API │     │
│  └─────────────┘    │         ▲            │   └───────────┘     │
└─────────────────────┘         │            └─────────────────────┘
                                │
                     ┌──────────┴──────────┐
                     │  Native Messaging   │
                     │  Host (Go binary)   │
                     │  Watches folder     │
                     └─────────────────────┘
```

### Components

| Component | Technology | Purpose |
|-----------|------------|---------|
| Interceptor DLL | C++ (MinGW) | Captures MAPI calls, writes JSON to `%TEMP%\go-mapi\` |
| Native Host | Go | Watches folder, bridges to browser via Native Messaging |
| Browser Extension | React + TypeScript | UI + Gmail API (Chrome & Edge) |

### Why This Architecture?

- **Enterprise-friendly**: DLL and host installed once with admin rights; extension updates independently
- **Simple OAuth**: Extension uses Chrome Identity API — no separate auth flow needed
- **Cross-browser**: Same extension works in Chrome and Edge
- **Debuggable**: JSON files on disk make the IPC trivially inspectable

## Installation

**For end users.** No terminal, no toolchain, no admin PowerShell required.

### Prerequisites

- Windows 10 or 11
- Chrome, Edge, Chromium, Brave, or Vivaldi
- A Gmail or Google Workspace account

### Install the Windows host

1. Download `go-mapi-setup.exe` from the latest GitHub Release:

   **[Direct download: go-mapi-setup.exe](https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe)**

   This link always points at the latest stable release.

2. Run the installer. You will see **one UAC prompt** — click **Yes**. The
   installer copies the binaries to `C:\Program Files\go-mapi\`, registers
   go-mapi as the default Windows Mail client, and writes native-messaging
   registry entries for Chrome, Edge, Chromium, Brave, and Vivaldi in one
   shot.

3. Install the browser extension. For v2.0.0 the Chrome Web Store listing
   is pending review — in the meantime, load the unpacked extension from
   the release ZIP asset attached to the same GitHub Release.

### If Windows SmartScreen blocks the installer

You may see a blue **"Windows protected your PC"** dialog when you first
run `go-mapi-setup.exe`. This happens because the v2.0.0 installer ships
unsigned — the project's code-signing certificate (via the SignPath
Foundation OSS program) is in review at the time of this release. The
installer is safe: the source is public on GitHub, and every release is
built from a reproducible GitHub Actions workflow (see
`.github/workflows/installer-release.yml`).

To continue the install:

1. Click the small **More info** link in the SmartScreen dialog.
2. A **Run anyway** button appears below the publisher line. Click it.
3. Proceed with the normal UAC prompt and installer wizard.

This is a one-time click-through per downloaded file — subsequent runs of
the same `go-mapi-setup.exe` don't show the dialog again. A signed
installer will ship as v2.0.1 once SignPath approval lands, at which
point this section becomes unnecessary.

## Usage

1. Right-click any file in Windows Explorer → **Send to** → **Mail recipient**
   (or trigger any other Windows "Send by Email" action).
2. The email appears in the go-mapi browser extension popup as a Gmail
   draft preview.
3. Click **Save as Draft** to push it to your Gmail drafts folder (or
   **Delete** to discard it).

That's it. No per-user setup, no extra prompts, and the extension
auto-detects the host once it's installed — if you install the extension
first and then the host, the extension's "Install go-mapi" banner
disappears within six seconds and a one-time success toast confirms the
handshake.

## Uninstall

Windows **Settings → Apps → Installed apps → go-mapi → Uninstall**, or
run the uninstaller directly at `C:\Program Files\go-mapi\unins000.exe`.

Uninstall removes every file and registry entry the installer wrote
(DLL, native host binary, all five browser registry trees, the MAPI
handler registration, `%TEMP%\go-mapi\` leftovers) and restores the
previous default Mail client from the backup file saved during install
(`C:\ProgramData\go-mapi\uninst\previous-mail-client.json`).

## Privacy

go-mapi is privacy-first by design:

- No telemetry of any kind. No update-check beacons, no crash reporting.
- No long-term storage of message content. Transient JSON files under
  `%TEMP%\go-mapi\` are deleted immediately after you click **Save as
  Draft** or **Delete**.
- No network calls except to the Gmail API, on your behalf, to create
  the draft.
- No background service, no tray icon, no auto-start.

## Enterprise Deployment

For managed Windows environments:

- **Silent install**: `go-mapi-setup.exe /VERYSILENT /SUPPRESSMSGBOXES` — the Inno Setup installer supports the standard `/VERYSILENT`, `/SILENT`, and `/LOG=<path>` switches. See the [Inno Setup Setup command line](https://jrsoftware.org/ishelp/index.php?topic=setupcmdline) documentation for the full list.
- **Extension deployment**: force-install via Chrome/Edge enterprise policy ([`ExtensionInstallForcelist`](https://chromeenterprise.google/policies/#ExtensionInstallForcelist)).
- **Registry**: all state is under `HKLM\SOFTWARE\Clients\Mail\go-mapi` and the five `HKLM\SOFTWARE\*\NativeMessagingHosts\com.gomapi.host` trees. Export these keys from a reference machine for GPO-based deployment if needed.
- **OAuth**: the extension uses the Chrome Identity API against a GCP OAuth client baked into `src/extension/public/manifest.json`. For enterprise deployments, fork the extension and replace the OAuth client ID with your own GCP project's credentials.

## Development

**For contributors building from source.** If you're just installing
go-mapi to use it, you want the [Installation](#installation) section
above instead.

### Prerequisites

- Windows 10/11 + Admin PowerShell
- Node 18+ and npm 9+
- Go 1.21+
- MinGW with gcc/g++ toolchain (for the C++ interceptor DLL)
- CMake 3.16+
- Chrome or Edge for extension testing

### Build everything

```powershell
npm ci                         # install extension dev dependencies
npm run build:interceptor      # MinGW + CMake → src/interceptor/build/bin/go-mapi.dll
npm run build:native-host      # Go → src/native-host/build/go-mapi-host.exe
npm run build:extension        # Vite → src/extension/dist/
```

### Install from local build (dev loop)

```powershell
# From an admin PowerShell on the build host:
.\scripts\install.ps1 -Local
```

The legacy `scripts/install.ps1` path is still supported for contributors
who want to test an unreleased build without compiling the Inno Setup
installer every iteration. It uses the same `.tmpl` native-messaging
manifests as the production installer (FOUND-06), so the resulting
registry state is identical.

### Build the Inno Setup installer locally

```powershell
& "C:\Program Files (x86)\Inno Setup 6\iscc.exe" `
    /DGOMAPIVersion=2.0.0-local `
    src\installer\go-mapi.iss
# → src\installer\dist\go-mapi-setup.exe
```

### Run the test suites

```powershell
cd src\native-host && go test ./... ; cd ..\..
cd src\interceptor && cmake .. -G "MinGW Makefiles" -DBUILD_TESTS=ON && cmake --build . && ctest --output-on-failure ; cd ..\..
cd src\extension && npm run test:run ; cd ..\..
npx playwright test --config tests\e2e\playwright.config.ts
```

### Local Windows Sandbox repro (REL-02)

See [`tests/sandbox/README.md`](tests/sandbox/README.md) for the local
install → verify → uninstall repro path. Requires Windows 11 24H2+ and
the `wsb` CLI.

### CI workflows

- `.github/workflows/build.yml` — per-PR Go + C++ + TypeScript build and test
- `.github/workflows/installer-smoke.yml` — per-PR Pester 5 installer smoke test on `windows-latest`
- `.github/workflows/e2e.yml` — Playwright happy-path + install UX on `windows-latest`
- `.github/workflows/go-race-nightly.yml` — nightly `go test -race` on `windows-latest` amd64
- `.github/workflows/installer-release.yml` — tag-triggered SignPath-gated installer release

### Troubleshooting a local install

- **DLL not found** — verify `C:\Program Files\go-mapi\go-mapi.dll` exists and `HKLM\SOFTWARE\Clients\Mail\go-mapi\DLLPath` points at it.
- **Extension shows "Install the go-mapi host" after installing** — wait up to 6 seconds for the reconnect alarm. If the prompt doesn't clear, check the service worker console in `chrome://extensions` and the host log at `%TEMP%\go-mapi\native-host.log`.
- **"Send to → Mail recipient" doesn't appear** — restart Windows Explorer (`taskkill /im explorer.exe /f && start explorer.exe`) so the shell picks up the new MAPI handler registration.

## Why "go-mapi"?

The name is a nod to "Go(ogle)" and "let's go". The project started as a pragmatic solution to the [Affixa shutdown](https://help.affixa.com/article/100-sunsetting-and-retirement-of-affixa).

## Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on:
- Setting up the development environment
- Building components
- Submitting pull requests

## License

go-mapi is Free Software licensed under the **GNU Lesser General Public License, version 3.0 or any later version** (`LGPL-3.0-or-later`).

- `LICENSE` — the full LGPL-3.0 text (additional permissions)
- `COPYING` — the full GPL-3.0 text (LGPL-3.0 is built on top of GPL-3.0)

See https://www.gnu.org/licenses/lgpl-3.0.html for the canonical license text and https://www.gnu.org/licenses/gpl-3.0.html for the underlying GPL-3.0.

## References

- [Simple MAPI Documentation](https://learn.microsoft.com/en-us/previous-versions/dd296734(v=vs.85))
- [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
- [Gmail API](https://developers.google.com/gmail/api)
- [Affixa Sunset Announcement](https://help.affixa.com/article/100-sunsetting-and-retirement-of-affixa)
