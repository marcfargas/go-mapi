# go-mapi

**The MAPI-to-Gmail bridge you always wanted.**

## Overview

[MAPI](https://en.wikipedia.org/wiki/MAPI) (Messaging Application Programming Interface) is a Microsoft Windows API that allows programs to become email-aware. It enables the "Send by Email" feature found in many Windows applications - from right-clicking a file in Explorer to printing to PDF and emailing it.

**Gmail and Google Workspace have no native MAPI support.** Despite Google Workspace being a major enterprise email solution, there has never been an official MAPI-to-Gmail bridge.

A few third-party tools have filled this gap over the years. The most notable, [Affixa](https://help.affixa.com/article/100-sunsetting-and-retirement-of-affixa), recently announced its shutdown - leaving Google Workspace users without a way to use "Send by Email" functionality.

**go-mapi** is the open-source replacement.

## Status

**v1.0.0 Stable** — Production-ready for personal and enterprise use.

| Component | Status |
|-----------|--------|
| MAPI interception (ANSI + Unicode) | ✅ Stable |
| Native messaging bridge | ✅ Stable |
| Browser extension (popup + notifications) | ✅ Stable |
| Gmail draft creation (with attachments) | ✅ Stable |
| UTF-8 / codepage encoding | ✅ Stable |
| Auto-detecting installer | ✅ Stable |
| Unattended installation mode | ✅ Stable |
| Comprehensive logging | ✅ Stable |
| Chrome & Edge support | ✅ Stable |

**What's Next:** Extension UI improvements, MSI installer. See [ROADMAP.md](ROADMAP.md).

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

## Quick Start

### Prerequisites

- Windows 10/11
- Chrome or Edge browser
- Gmail or Google Workspace account

### Installation

1. **Install the extension** in Chrome or Edge:
   - Chrome Web Store: [Install go-mapi](https://chrome.google.com/webstore) (under review)
   - Edge Add-ons: [Install go-mapi](https://microsoftedge.microsoft.com/addons) (under review)
   - Or load unpacked from a [release zip](https://github.com/marcfargas/go-mapi/releases)

2. **Run the installer** (admin PowerShell):
   ```powershell
   irm https://raw.githubusercontent.com/marcfargas/go-mapi/main/scripts/install.ps1 | iex
   ```
   
   The installer will:
   - **Auto-detect** the extension ID from your browser profiles (no copy-paste needed!)
   - Download the latest release from GitHub
   - Install binaries to `C:\Program Files\go-mapi\`
   - Register the MAPI handler
   - Set up native messaging for Chrome and Edge
   
   **Fully automated** — just install the extension first, then run the command above.

### Usage

1. Right-click any file in Windows Explorer → "Send to" → "Mail recipient"
2. The email appears in the go-mapi extension popup
3. Click "Save as Draft" or "Send Now"

### Advanced Install Options

```powershell
# Fully automated (no prompts, for CI/automation)
.\install.ps1 -Unattended

# Pin a specific version
.\install.ps1 -Version "v0.1.0"

# Custom install directory
.\install.ps1 -InstallDir "D:\go-mapi"

# Manually specify extension ID (if auto-detection fails)
.\install.ps1 -ExtensionId "abcdefghijklmnopqrstuvwxyz123456"

# Developer: install from local build instead of GitHub
.\install.ps1 -Local
```

### Troubleshooting

**Installer can't find extension:**
- Make sure you've installed the extension in Chrome or Edge first
- Check `chrome://extensions` - the extension should be listed
- If auto-detection fails, manually specify: `.\install.ps1 -ExtensionId "your-32-char-id"`

**Installation logs:**
- Check `C:\Program Files\go-mapi\install.log` for detailed error messages

**"Send to → Mail recipient" doesn't work:**
- Restart Windows Explorer (or reboot)
- Verify DLL is registered: check `HKLM:\SOFTWARE\Clients\Mail\go-mapi`

### Uninstall

```powershell
# Full uninstall (admin PowerShell)
.\install.ps1 -Uninstall

# Registry-only (keep files)
.\install.ps1 -Uninstall -KeepFiles
```

The uninstaller removes all registry entries and restores your previous default mail client.

## Enterprise Deployment

For managed environments:

- **Automated Install**: Use `.\install.ps1 -Unattended` in SCCM/Intune deployment scripts
- **Extension**: Force-install via Chrome/Edge enterprise policy ([`ExtensionInstallForcelist`](https://chromeenterprise.google/policies/#ExtensionInstallForcelist))
- **Registry**: Export keys from `HKLM:\SOFTWARE\Clients\Mail\go-mapi` for GPO deployment if needed
- **OAuth**: Create a GCP project, enable Gmail API, and configure an OAuth 2.0 client ID (Chrome Extension type)

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
