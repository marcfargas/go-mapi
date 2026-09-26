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

You'll need a Gmail or Google Workspace account. The first time you launch
go-mapi it will open a Google sign-in page in your browser so it can create
drafts on your behalf. That's the only sign-in step.

## Install

The **system component** provides machine-wide Windows MAPI integration and
requires administrator consent for its initial installation. The **user
component** is the tray app and Gmail client; each Windows user keeps their own
settings, queue, and Gmail sign-in.

The matrix below describes the v4 package and update design. Source builds
currently identify as `0.0.0-dev`; there is no public v4 release candidate.
See [DEVELOPMENT.md](DEVELOPMENT.md) for release-track rules. The resident
service can check authenticated metadata and publish discovery status when a
complete trusted root is embedded. Automatic machine installation and public
first-party release endpoints remain separate delivery work.

| Install method | What it installs | Update behavior |
| --- | --- | --- |
| System-component MSI | System component and one resident service | The service checks only the installed system release track when enabled and trusted metadata is configured. Optional silent installation is planned separately. Use a separate user-level user component. |
| Suite MSI | System component, all-users user component, and the same resident service | The service checks only the installed suite release track. Optional automatic installation will replace the bundle together, after that capability is delivered. |
| User-level user-component package | User component for one Windows user; no updater service | The app automatically checks supported distribution channels and offers a user-initiated Store, package-manager, or installer action. It retains system compatibility and repair guidance and system availability advice until verified automatic service maintenance is operational. |

The two MSIs are alternative machine-wide installs, not packages to install
side by side. A change between them requires an explicit administrator-approved
migration. A suite install needs no separate user-level package; existing
user-level installations are left alone.

For a machine MSI, an administrator can choose the managed-update setting at
install or repair time. Use the MSI file you intend to install in an elevated
terminal. For a new installation:

```powershell
$msi = 'C:\Install\go-mapi-system-x64.msi' # use the actual system or suite MSI filename
msiexec /i $msi GOMAPI_AUTO_UPDATE=0 /qn /norestart
msiexec /i $msi GOMAPI_AUTO_UPDATE=1 /qn /norestart
```

To change an existing installation, explicitly reinstall its registry values:

```powershell
msiexec /i $msi REINSTALL=ALL REINSTALLMODE=amus GOMAPI_AUTO_UPDATE=0 /qn /norestart
msiexec /i $msi REINSTALL=ALL REINSTALLMODE=amus GOMAPI_AUTO_UPDATE=1 /qn /norestart
```

`0` disables unattended installs; `1` enables them once the signed managed-update path is available. A new
machine install defaults to `1`. Repair and same-package upgrades preserve a
valid existing choice unless an administrator uses the explicit reinstall command above. If
the existing machine setting is missing or invalid, supply an explicit choice
to repair it. A disabled setting does not stop service health and status. A
full Windows **Restart** may be needed to verify an interrupted installation;
signing and end-to-end update delivery remain under validation.

During v4 development, use only a selected test distribution. Machine release
checking waits two minutes after service startup, uses a six-hour successful
cadence and bounded persistent retry delays. The per-user app checks on startup
when its previous attempt is at least 24 hours old, then checks daily while
enabled. System, suite and user packages have independent release cadences;
one package's availability does not imply another is ready. The service can
start and report local health even when metadata or the network is unavailable.

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

The v4 resident service checks the installed MSI's authenticated system or
suite release track without a signed-in user. This discovery step identifies
an immutable candidate but never runs an installer. Optional silent machine
installation is a later capability. The separate user-level package checks
automatically but only the user can start its Store, package-manager or
installer action. Compatibility and repair guidance remains visible; system
availability advice is hidden only when fresh trusted status proves automatic
machine maintenance is actually working. Initial machine installation and
explicit repair require administrator consent.

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
