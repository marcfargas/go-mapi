# go-mapi

> Right-click any file in Windows Explorer, click "Send to → Mail recipient",
> and the email appears ready to send in Gmail.
>
> No configuration. No subscription fees. [Completely open source](https://github.com/marcfargas/go-mapi).

[![Watch the demo](https://img.youtube.com/vi/gxTpMXVdP40/maxresdefault.jpg)](https://youtu.be/gxTpMXVdP40)

## What it does

go-mapi connects the "Send to Mail recipient" feature in Windows to your
Gmail account. Any Windows app that has that option — File Explorer, Word,
Excel, legacy line-of-business software — will route the email to Gmail
instead of Outlook, as a draft you can review before sending.

This uses Simple MAPI. It requires the go-mapi system component and the
running user app, signed in to Gmail. A suite installation includes both;
installing only the user app does not install the system component. go-mapi
does not currently handle mailto links or register a MAILTO handler in
Windows Default Apps.

**Nothing about how you work changes.** You keep using your apps the way
you always have. go-mapi sits quietly in the background and the draft just
shows up in your Gmail inbox.

- Works with any Windows app that uses "Send to Mail recipient"
- Drafts land in Gmail — review and send normally, nothing is sent automatically
- Manual or automatic draft creation (your choice)
- Your emails go directly to Gmail's servers — nowhere else. Update checks use
  our first-party service only for privacy-minimized aggregate adoption
  statistics; they never include email, account, or message data.

## Before you install

Use a supported Windows 10/11 x64 machine with Microsoft Edge WebView2 Evergreen
Runtime installed, plus a Gmail or Google Workspace account. The current split
packages do not bundle the runtime; if it is missing, install it from Microsoft's
[WebView2 download page](https://developer.microsoft.com/microsoft-edge/webview2/).
The first time you launch go-mapi it opens a Google sign-in page in your browser
so it can create drafts on your behalf. That's the only sign-in step.

## Install

The **system component** provides machine-wide Windows MAPI integration and
requires administrator consent for its initial installation. The **user
component** is the tray app and Gmail client; each Windows user keeps their own
settings, queue, and Gmail sign-in.

v4 is still being qualified. Choose one machine installation path below; use a
selected test distribution until the release is approved. The current component
version files are prereleases, not a public v4 release-readiness statement.

| Install path | Scope and contents | Who updates it |
| --- | --- | --- |
| **Suite MSI** | Administrator installs the interceptor, resident service and app for all users. Each user signs in separately. | The service can silently update the suite together from its authenticated suite track when managed updates are enabled. |
| **System MSI + separate user app** | Administrator installs interceptor/service once; each user installs their preferred app channel below. | The service maintains only the system MSI. Each user's app follows its own channel. |
| **Direct user installer (NSIS)** | One user's app under `%LOCALAPPDATA%\Programs\go-mapi`, without elevation or machine registration. | The app checks for updates and offers a user-initiated installer action. |
| **winget user package** | The same per-user standalone installer, package ID `MarcFargas.go-mapi`. | User-initiated package-manager action; catalog availability depends on publication and merge. |
| **Microsoft Store app (MSIX)** | One user's app, without machine registration. | Store-managed distribution; app guidance opens the Store. Availability depends on certification and listing. |

For the complete product, choose **suite**, or **system plus one user-app channel**.
App-only installation can start without the system component but cannot provide
Windows Send-To integration. A suite needs no separate per-user app installation.
The system and suite MSIs are alternatives; changing between them requires an
explicit administrator-approved migration. Existing per-user packages and user
data are not removed by machine installation—avoid running duplicate app channels.

For a selected test MSI, double-click it and accept administrator consent, or use
the [administrator deployment commands](ENTERPRISE.md#install-repair-and-remove).
That guide covers silent install, managed-update opt-out, repair and migration.
A new machine install defaults managed updates on. Real unattended delivery
requires trusted signed packages and configured release metadata; implementation
and fixture tests alone do not qualify the public release.

After installing the needed components, start go-mapi and sign in with your
Gmail or Google Workspace account when prompted.

go-mapi runs in the Windows notification area (the icons next to your
clock). Click its icon to open the window or change settings.

> **Upgrading from go-mapi v2.x?**
> Uninstall v2.x first via **Settings → Apps → Installed apps**, then install
> the new version. Running both side-by-side is not supported.

## How to use it

Once installed, trigger "Send to Mail recipient" in any Windows app as you
normally would. go-mapi intercepts the request and shows you the draft in its
window before anything goes to Gmail.

**Manual mode** (default): go-mapi shows you each email and waits for you to
click "Create draft". Nothing reaches Gmail until you say so.

**Auto mode**: go-mapi creates the draft immediately and tells you it's ready
in your inbox. Switch between modes in the go-mapi window.

## Updates

The resident LocalSystem service checks the installed **system** or **suite**
track and can download, verify and silently install an eligible same-SKU update.
It does not switch between system and suite. Suite updates coordinate shutdown
and launch admission for the machine app; users retain their settings and Gmail
sign-in. This path is implemented and exercised by development fixtures; final
signed-release, reboot and no-user qualification remain separate requirements.

Administrators can disable unattended machine updates without removing service
health/status reporting. See [managed updates](ENTERPRISE.md#managed-updates).
Per-user direct/winget updates require user action; Store distribution is managed
through the Store. Initial machine installation, explicit repair and SKU migration
require administrator consent. Machine and per-user packages have independent
release cadences; availability of one does not imply another is ready.

Update checks contact `go-mapi.app` and report only
the app version, distribution channel, operating system, and coarse
country/area aggregates. They do not use an install identifier, cookies, or
your email/account data.

## License

LGPL-3.0-or-later — free and open source, anyone can inspect the code.
See [LICENSE](LICENSE).

---

For IT departments and admins deploying go-mapi at scale (RDS, Citrix, silent
install, group policy), see [ENTERPRISE.md](ENTERPRISE.md).

For contributors and maintainers, see [DEVELOPMENT.md](DEVELOPMENT.md).
