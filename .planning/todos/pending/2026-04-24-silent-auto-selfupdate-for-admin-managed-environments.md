---
created: 2026-04-24T15:21:05.991Z
title: Silent auto-selfupdate for admin-managed environments
area: autoupdate
files:
  - src/app/ (autoupdate wiring — Phase 11 notify-only baseline)
---

## Problem

Phase 11 ships autoupdate as **notify-only** (tray toast + "download" link via `creativeprojects/go-selfupdate`). That assumes the logged-in user can run an installer — which breaks in locked-down admin-managed environments where:

- End users are non-admins and cannot elevate to run the NSIS installer.
- The admin trusts our release artefacts and wants the app to update itself unattended across the fleet without touching every machine.
- Notify-only toasts become noise because users can't act on them.

Without a silent-update path, these deployments freeze on whatever version the admin rolled out — defeating the point of autoupdate and forcing manual re-packaging for every release.

## Solution

TBD — rough shape:

- A Windows **Scheduled Task** (or background helper service) running under an account with write access to `%PROGRAMFILES%\go-mapi\` handles the download + swap, so the interactive user never needs elevation.
- Reuse the `creativeprojects/go-selfupdate` feed already wired for notify mode; switch behaviour from "surface toast" to "download + apply" when `auto_selfupdate: true` is set in the machine-wide config (see sibling todo `machine-wide-config-file-in-programdata`).
- Installer registers the scheduled task at install time (NSIS `schtasks.exe /create`), under `All Users` install scope. Uninstaller tears it down.
- Swap strategy must handle the running `go-mapi.exe` — likely "stage new binary, schedule replace on next app launch / reboot" to avoid killing a live Wails process.
- Release signing matters: the scheduled-task helper must verify the downloaded artefact against SignPath (or equivalent) before swapping — otherwise an attacker who can write to the update URL owns every managed endpoint.

Gated by the machine-config flag so default (consumer) deploys stay notify-only.

Related: `machine-wide-config-file-in-programdata` (config surface this depends on), `ship-machine-and-user-config-yaml-example-files` (examples admin uses to turn this on). Fits v3.1+ milestone planning; natural pair with the "Installer: All Users scope" seed at `.planning/seeds/installer-all-users-scope.md`.
