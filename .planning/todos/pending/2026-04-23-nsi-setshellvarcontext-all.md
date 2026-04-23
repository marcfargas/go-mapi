---
created: 2026-04-23T12:30:00.000Z
title: NSIS installer — add SetShellVarContext all for Start Menu shortcut
area: installer
files:
  - src/installer/go-mapi.nsi
---

## Problem

`src/installer/go-mapi.nsi:372-387` creates the Start Menu shortcut via `$SMPROGRAMS\go-mapi.lnk`. The comment on lines 373-374 claims "all-users (admin install → $SMPROGRAMS resolves to %ProgramData%\Microsoft\Windows\Start Menu\Programs\)" — **this is incorrect**. NSIS' `$SMPROGRAMS` default context is "current", which resolves to the per-user folder (`%APPDATA%\Microsoft\Windows\Start Menu\Programs`) even when `RequestExecutionLevel admin` is set.

Discovered during Phase 11 clean-machine smoke on 2026-04-23: the Start Menu shortcut landed in `C:\Users\WDAGUtilityAccount\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\go-mapi.lnk` rather than the expected `C:\ProgramData\Microsoft\Windows\Start Menu\Programs\go-mapi.lnk`. On multi-user real-world Windows machines, the shortcut would only appear for the admin account that ran the installer, not for all users as D-13 intended.

## Fix

Wrap the shortcut block (and the matching Delete in the uninstall section around line 445-446) with `SetShellVarContext all`:

```nsis
Function CreateShortcutAndAUMID
  SetShellVarContext all    ; resolve $SMPROGRAMS → %ProgramData%\...
  CreateShortcut "$SMPROGRAMS\go-mapi.lnk" ...
  ApplicationID::Set "$SMPROGRAMS\go-mapi.lnk" "${AUMID}"
FunctionEnd
```

Uninstall path:
```nsis
  SetShellVarContext all
  Delete "$SMPROGRAMS\go-mapi.lnk"
```

Matching harness fix already landed in `tests/sandbox/phase11/Run-Phase11Smoke.ps1` `Launch-App` — it checks both locations — but the real fix belongs in the installer.

## Risk

Low. Behaviour change only affects where the shortcut lands; both locations work from the user's perspective in single-user installs. The fix aligns the code with the already-correct comment and with D-13's stated intent.

## Verification

Rebuild installer, install on a fresh Windows VM, verify `%ProgramData%\Microsoft\Windows\Start Menu\Programs\go-mapi.lnk` exists and `%APPDATA%\Microsoft\Windows\Start Menu\Programs\go-mapi.lnk` does not.
