---
title: "Investigate: installer fails to overwrite 32-bit go-mapi.dll on in-place reinstall"
trigger_condition: "v3.1 milestone planning, or sooner if a user hits it on upgrade and can't work around via uninstall-first"
planted_date: 2026-04-23
---

## Idea

Figure out why `go-mapi-setup.exe`, when run over an existing install, errors specifically on `$PROGRAMFILES32\go-mapi\go-mapi.dll` ("file not writable") while every other file in the install set overwrites cleanly. Manual elevated delete of the DLL succeeds (so it's **not** a kernel-level DLL-load lock), and a subsequent rerun of the installer completes normally.

## Why

Quality-of-life bug for the upgrade path. First-time installs are unaffected. Uninstall-first-then-reinstall is a viable workaround, but the "rerun the setup" upgrade flow is what end users will naturally try. Failing on that path damages trust in the installer.

## Breadcrumbs

- Hand-delete (Explorer, elevated) works → rules out `LoadLibrary` mapping lock, rules out hard ACL denial.
- The file lives under `$PROGRAMFILES32` (x86 path); only the x86 DLL block hits this, not the x64 DLL.
- Likely suspects to audit:
  - `SetOverwrite` directive state around the x86 `SetOutPath` block in `src/installer/go-mapi.nsi` — may inherit `ifnewer` / `try` instead of `on`.
  - UAC file virtualisation quirk if the DLL's ACL was written under a different elevation context in a prior install.
  - Transient AV lock on upgrade (Defender real-time scan touching the new DLL candidate).
  - Race between the auto-triggered uninstall step of the previous install and the new file write.
- Companion bug todo: `.planning/todos/pending/2026-04-23-installer-overwrite-locked-32bit-dll.md`.

## When to surface

During v3.1 milestone planning. If a user reports the failure without knowing the workaround, promote to a v3.0.x quick-phase sooner.

## Risk / constraints

- Fix must not regress clean-install path.
- Any retry loop must bound itself (don't spin forever on an AV that never releases).
- If the fix lands in NSI, re-run Pester 5 smoke from Phase 10-05 to confirm install + upgrade + uninstall all still pass.
