---
title: "\"Start at logon\" option"
trigger_condition: "v3.1 milestone planning, or earlier if a user reports having to launch go-mapi manually before using a MAPI app"
planted_date: 2026-04-23
---

## Idea

Give the user a settings toggle for "Start go-mapi when I log in to Windows". When enabled, the installer (or the app itself, on first toggle) registers an entry in `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (or a Startup-folder shortcut) that launches `go-mapi.exe --minimised` at logon.

## Why

Right now go-mapi only starts when the user launches it from the Start Menu shortcut. If a legacy Simple-MAPI app calls `MAPISendMail` before the Wails app has been started that session, the DLL writes the JSON + attachments into `%LOCALAPPDATA%\go-mapi\queue\`, but nothing surfaces to the user — the queue just fills silently. The first-run UX is: user wonders why "nothing happened" when they clicked Send.

A startup toggle solves the 80% case without pulling in the heavier "launch-on-MAPI-trigger from inside the DLL" seed (see `interceptor-launches-wails-app.md` — companion seed).

## Breadcrumbs

- AppSettings already persists via `settings.go` atomic-write (Phase 9 D-13); add a `StartAtLogon bool` field + `ApplyStartAtLogon(bool)` method that writes/removes the Run-key entry.
- Tray menu + Settings panel already exist — drop a new toggle row beside the update toggle.
- NSIS installer can offer the option at install time (checkbox on the "finish" page) and wire the initial Run-key state, so the 90% of users who expect "installed = works" get it by default.
- Decide default: **on for installer-driven installs** (best UX), **off for wails dev runs** (no dev-mode surprise).

## When to surface

During v3.1 milestone planning, OR as a v3.0.1 quick-phase if user feedback on first-run UX comes back negative. The feature is small (est. 1-2 plans) but touches installer + settings + tray + frontend.

## Risk / constraints

- Must not silently re-enable itself after the user explicitly turns it off (respect the persisted `false`).
- Respect Windows' per-user startup scope — never write the `HKLM` Run key (that would affect all users on the machine, wrong default).
- Uninstaller must scrub the Run-key entry.
