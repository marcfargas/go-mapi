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

go-mapi v4 is split into two independently serviced packages:

- The **user component** is the per-user tray application and Gmail client.
- The **system component** is the machine-wide Windows MAPI integration. Its
  installation requires administrator consent.

During the v4 release-candidate period, install both packages from the selected
test distribution. The final stable download locations will be published here
only after the signed Store/WinGet release path has passed end-to-end
verification.

After installing both components, start go-mapi and sign in with your Gmail or
Google Workspace account when prompted.

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

go-mapi tells you when either component has a compatible update. You choose
when to install it — updates are never installed without your say-so. The user
component can download a verified system-component installer and asks for
administrator consent only when Windows is ready to install it. Update checks
contact `go-mapi.app` and report only
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
