---
title: "Installer: offer All Users scope for Start Menu shortcut (default All Users)"
trigger_condition: "v3.1 milestone planning, or sooner if a multi-user workstation/RDS admin reports the shortcut missing for other users after install"
planted_date: 2026-04-24
---

## Idea

At install time, let the user choose between **All Users** (per-machine) and **Current User** (per-user) install scope, and default to **All Users**. Today the Start Menu shortcut and AUMID registration land in the current user's profile only — on multi-user boxes (RDS sessions, shared desktops), a second user logging in finds no shortcut even though `go-mapi.exe` is installed under `%PROGRAMFILES%`.

## Why

The app already installs the binary and DLL machine-wide (`$PROGRAMFILES`/`$PROGRAMFILES32`), but the Start Menu shortcut, AUMID, and (likely) the autostart/Run-key entry are per-user. That split is confusing: an admin who installs for the whole team expects "installed = available to everyone". Defaulting to All Users is the conventional Windows installer behaviour and matches how users reason about enterprise/RDS deploys.

Current User must still be available — some users don't have elevation, and per-user installs are the correct choice on locked-down machines where `$PROGRAMFILES` writes are denied.

## Breadcrumbs

- Phase 10 (10-01, 10-03, 10-04) owns the NSIS installer + Start Menu shortcut + AUMID + uninstaller; the scope switch lives there.
- NSIS has `MultiUser.nsh` (NsisMultiUser plugin) that handles the All Users / Current User branching cleanly, including elevation prompt and registry-scope switch (HKLM vs HKCU).
- Companion to `start-at-logon.md` seed — the Run-key entry decision (HKCU per-user vs HKLM per-machine) must line up with the chosen scope. HKLM Run applies to every user on the box, which is the right call under All Users scope but wrong under Current User.
- Uninstaller must scrub whichever scope was used — detect at uninstall time (InstallMode/InstallScope registry markers).
- AUMID registration currently writes under HKCU; under All Users it should go to HKLM so toasts persist in Action Center for every user session.

## When to surface

During v3.1 milestone planning. Pairs naturally with the "Start at logon" seed and with any multi-user UX work. Estimated 1-2 plans — small but touches installer + uninstaller + registry-scope branching throughout.

## Risk / constraints

- All Users install requires elevation — installer UX must handle the UAC prompt gracefully and fall back to Current User if declined (or re-prompt).
- Uninstaller must detect install scope before choosing which hives to scrub; getting this wrong leaves either residue (under-scrub) or breaks another user's install (over-scrub).
- Mixed-scope states (v3.0 Current User already installed, then All Users reinstall) need a migration path — probably "uninstall old first, then install new" with a clear installer message.
- The `interceptor-launches-wails-app.md` and `start-at-logon.md` seeds both assume a launch mechanism; revisit them once the scope decision is made.
