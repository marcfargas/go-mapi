# go-mapi admin MSI

This directory owns the machine-wide interceptor package. It never packages or
launches the Wails app and never changes the user's Windows Default Apps choice.
The MSI always activates `go-mapi` as the legacy Simple MAPI provider in both
the shared HKLM registration uses a `REG_EXPAND_SZ` path containing
`%ProgramW6432%` and `%PROCESSOR_ARCHITECTURE%`. The MAPI stub expands it in
the caller process, selecting `AMD64\go-mapi.dll` for x64 callers and
`x86\go-mapi.dll` for legacy callers.

`build.ps1` consumes the independently verified interceptor artifact manifest.
It rejects a missing architecture, hash/PE/version disagreement, development
version, and (with `-RequireSignedInputs`) unsigned DLLs. The Windows release
build packages the x64 DTF custom action and creates
`release/admin/go-mapi-interceptor.msi`.

The custom action consumes `legacy-inventory.json`. Cleanup is unconditional on
install, silent install, repair, and upgrade; there is no cleanup-disable MSI
property. Before mutation it records the original native and WOW64 active MAPI
provider in `%ProgramData%\go-mapi\installer-journal\admin-migration-v1.json`.
Rollback removes partial v4 state and restores an earlier provider only when its
client key still exists. Exact product paths/names are the deletion boundary.
The old NSIS uninstaller is never invoked.

Only after both DLL files and registry views verify does the custom action
atomically write
`%ProgramFiles%\go-mapi\interceptor\installed-component-v1.json`. Its schema is
checked in under `schema/`; the paths are relative to the manifest directory and
match the app/interceptor version-gate contract.

Windows validation runs:

```powershell
.\src\installer\msi\build.ps1 -Version 4.0.0 -ArtifactDirectory release\interceptor
.\src\installer\msi\verify.ps1 -MsiPath release\admin\go-mapi-interceptor.msi
.\src\installer\msi\tests\AdminLifecycle.Tests.ps1 -MsiPath release\admin\go-mapi-interceptor.msi
```

The lifecycle script seeds manual-registration, NSIS, update-staging, stale-file,
and dual-view fixtures; exercises install, repair, rollback, and uninstall; and
preserves per-user Wails data. Run it only on a disposable elevated Windows VM.

Public publication is signed-only. `admin-release.yml` signs both DLLs, then the
MSI, verifies the result, emits immutable release metadata, and generates/submits
the elevated machine-scope winget manifest. Microsoft Store publication remains
the independently built user package's workflow; `admin-release.json` is the
cross-channel coordination record and does not embed that package.
