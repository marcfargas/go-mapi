---
created: 2026-04-24T15:21:05.991Z
title: Ship go-mapi.machine.yaml.example + go-mapi.user.yaml.example
area: config
files:
  - src/app/ (config-loading code once it lands)
  - src/installer/ (NSIS copies examples into PROGRAMDATA / APPDATA at install time)
---

## Problem

Once the machine + user config surface lands (sibling todo `machine-wide-config-file-in-programdata`), admins and power users need a discoverable template to understand:

- Which keys exist and what they do.
- Which keys are machine-scope vs user-scope (and which can be locked).
- Default values and allowed enumerations.
- Precedence rules (machine → user → env var).

Without shipped examples, the only documentation is source code — which is a terrible onboarding experience for admins doing MSI-style fleet rollouts, and wrong for a "privacy-first, no-telemetry, local-first" app whose config surface is a first-class feature, not an escape hatch.

## Solution

TBD — rough shape:

- **Artefacts:** `go-mapi.machine.yaml.example` and `go-mapi.user.yaml.example` committed to the repo (likely at `src/app/config/examples/` or similar), bundled into the NSIS installer.
- **Installer behaviour:**
  - Copy `go-mapi.machine.yaml.example` to `%PROGRAMDATA%\go-mapi\` at install time (do NOT copy as the live `go-mapi.machine.yaml` — preserve the "config absent = defaults" contract).
  - Copy `go-mapi.user.yaml.example` into the install dir under `%PROGRAMFILES%\go-mapi\examples\` so each user can copy-and-edit it into their own `%APPDATA%\go-mapi\go-mapi.user.yaml` when they want local overrides.
- **Content:** every key fully documented inline (YAML comments with default, allowed values, machine-vs-user scope, lockability). Mirror the structure the loader in the config todo ends up supporting.
- **Versioning:** include a `schema_version:` field in both examples so the loader can warn on mismatched versions after config-schema changes land.
- **Release gate:** updating the examples is part of the definition-of-done for any future task that adds a config key — document that rule in CLAUDE.md once this ships so the docs can't drift from the loader.

Soft-dependency on `machine-wide-config-file-in-programdata` (examples only make sense once a schema exists). Fits the same v3.1+ milestone window.
