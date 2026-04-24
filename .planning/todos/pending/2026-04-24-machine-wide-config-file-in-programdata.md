---
created: 2026-04-24T15:21:05.991Z
title: Machine-wide config file in %PROGRAMDATA%
area: config
files:
  - src/app/paths.go (path resolution lives here)
  - src/app/app.go (bindings would expose effective config)
---

## Problem

go-mapi has no machine-wide configuration surface today. Everything is per-user: OAuth tokens in Windows Credential Manager (`service=go-mapi`, `user=oauth-tokens`), `hasSeenPreAuthExplainer` in the frontend, logs/queue under `%APPDATA%` and `%LOCALAPPDATA%`.

That blocks three things:

1. **Admin-managed deploys** can't centrally flip behaviour (e.g. enable silent auto-selfupdate — see sibling todo `silent-auto-selfupdate-for-admin-managed-environments`) without editing every user's profile.
2. **Future control-plane seeding**: a central MDM / policy service needs a well-known machine-writable file it can drop config into at provisioning time, independent of which users eventually log in to the box.
3. **Per-machine defaults**: some settings (update channel, update interval, telemetry off, log verbosity) are a property of the endpoint, not the user — forcing them into per-user state is the wrong model.

## Solution

TBD — rough shape:

- **Path:** `%PROGRAMDATA%\go-mapi\go-mapi.machine.yaml` (default: `C:\ProgramData\go-mapi\go-mapi.machine.yaml`). Readable by everyone, writable only by Administrators — enforce via installer ACLs at directory-create time.
- **Format:** YAML (matches existing seed for example files). Minimal v1 surface: `auto_selfupdate: bool`, `update_channel: stable|beta`, `update_interval_hours: int`, `log_level: info|debug`. Grow the schema as features land.
- **Layering:** machine → user → env var, with user overrides allowed only for keys the machine doesn't lock. Machine config may carry a `locked: [keys]` list so admin-managed fleets can pin settings the user can't override.
- **Loading:** resolve at `NewApp()` via `paths.go` helper; expose effective config to frontend via a new `GetEffectiveConfig()` Wails binding so the UI can grey out admin-locked settings.
- **User-facing file:** `%APPDATA%\go-mapi\go-mapi.user.yaml` (per-user overrides). Sibling todo `ship-machine-and-user-config-yaml-example-files` covers shipping `.example` templates for both.
- **Back-compat:** no existing config to migrate — greenfield surface.

Control-plane seeding is deliberately out of scope for the first cut; the point here is to have a file a control plane *can* write into later, not to build the control plane.

Fits v3.1+ milestone planning. Hard-dependency for the silent-selfupdate todo.
