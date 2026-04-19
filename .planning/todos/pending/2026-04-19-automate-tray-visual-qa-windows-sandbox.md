---
created: 2026-04-19T15:55:00.000Z
title: Automate tray icon + menu visual QA via Windows Sandbox + UI Automation
area: test-hygiene
files:
  - .planning/phases/09-queue-automode-toasts/09-05-PLAN.md
  - .planning/phases/09-queue-automode-toasts/09-05-SUMMARY.md
  - src/app/tray.go
  - src/app/tray_test.go
---

## Problem

Plan 09-05 (tray has-queue icon + Pause/Resume menu) currently includes a `autonomous: false` manual-QA checkpoint requiring a human to build, launch, and visually inspect tray behavior on a real Windows desktop. Same pattern will recur for every future tray/window/systray/shell change.

Unit tests cover the pure `computeTrayVisual()` state machine, but they cannot observe:
- Actual `Shell_NotifyIcon` icon swap on the live tray host
- Tooltip string rendering when hovered
- Pause/Resume menu label toggle on right-click
- Icon priority (error > has-queue > idle) end-to-end

User preference (feedback memory 2026-04-19): prefer automated tests over manual human-verify for Windows shell behavior. This is a recurring cost — every tray/menu/window change in v3.0 and beyond triggers the same 5-check manual QA.

## Solution

Build an automated tray visual QA harness using **Windows Sandbox + FlaUI (UI Automation)**:

1. **Windows Sandbox config** (`.wsb` file) — maps build output + test fixtures, runs startup script
2. **Test runner** — PowerShell/Go wrapper that:
   - Boots the sandbox, launches `go-mapi.exe`
   - Uses FlaUI (`FlaUI.Core` via pwsh binding) or WinAppDriver to locate the tray overflow area
   - Asserts icon handle and tooltip text via UI Automation
   - Right-clicks tray, finds `Pause watching` MenuItem by name, invokes click, re-queries label
   - Drops fixture JSON into `%TEMP%\go-mapi\` to trigger queue state changes
3. **CI integration** — self-hosted Windows runner or VM image with Sandbox feature enabled (GitHub-hosted `windows-latest` can't run Sandbox — need own infra)

Scope boundary: this replaces the 5-check manual QA in Plan 09-05, covers future tray changes, and surfaces regressions pre-merge. Does NOT replace toast-activation manual QA (that requires a real user session with notification permissions).

## When to tackle

Candidate points:
- **v3.1 or v3.2 milestone** — after v3.0 ships; accepting technical debt that manual QA is deferred for 09-05, 09-06 toast, 09-09 wiring
- **Before Phase 10 installer work** — installer QA will benefit from sandbox automation too (registry, shortcuts, file-association round-trip)

Outstanding cost of deferring: every tray/window/menu plan in v3.0 carries a manual QA step for the user.

## Related

- **Plan 09-05 deferred manual QA** — tracked as outstanding. Resolves automatically when this todo lands.
- **Plan 09-06 toast** — similar manual QA shape; sandbox harness extension candidate once built.
- **Plan 09-09 wiring** — has a visible-path drafted-flash check; could also be sandbox-automated.

## References

- FlaUI: https://github.com/FlaUI/FlaUI (UI Automation wrapper for .NET)
- WinAppDriver: https://github.com/Microsoft/WinAppDriver (Appium spec for Windows)
- Windows Sandbox config: https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file
- Shell_NotifyIcon + UI Automation considerations: https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyiconw
