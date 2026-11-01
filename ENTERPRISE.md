# go-mapi for IT administrators

For managed Windows desktops and RDS/Citrix deployment planning. v4 is still
under qualification; use a selected test distribution. See the
[installation matrix](README.md#install) before choosing packages.

## Choose the deployment scope

- **Suite MSI:** machine-wide interceptor, resident LocalSystem service and app.
  Each signed-in Windows user owns their settings, queue and Gmail credentials.
- **System MSI:** interceptor and the same service, without an app. Pair it with
  each user's direct/winget or Store app.
- **Per-user app:** direct NSIS and winget share one standalone identity;
  Store uses MSIX. These packages need no elevation and install no machine service
  or MAPI provider. A suite needs no additional user-app package.

System and suite are mutually exclusive MSI products. Their update tracks and
release versions are independent. A machine install does not inventory or remove
per-user packages/data; plan channel selection to avoid duplicate consumers.
The legacy all-users `go-mapi-setup.exe` and `/AUTOUPDATE=1` scheduled-task model
are not the v4 deployment interface.

## Install, repair and remove

Use an elevated administrator PowerShell for machine MSI commands. Select the
actual signed package and verify its identity before execution. The filenames
below are placeholders for that selected distribution, not download links.

```powershell
$msi = 'C:\Install\go-mapi-suite-<release>-x64.msi' # or the system MSI
$process = Start-Process msiexec.exe -ArgumentList @('/i', ('"' + $msi + '"'), 'GOMAPI_AUTO_UPDATE=1', '/qn', '/norestart', '/l*vx', 'C:\Install\go-mapi-install.log') -Wait -PassThru
$process.ExitCode
```

A new machine install defaults `GOMAPI_AUTO_UPDATE` to `1`; use `0` to disable
unattended updates. Inspect the exit code and verbose log. `0` is success;
`3010` requires a real Windows restart and postboot inspection. Do not treat a
failed transaction or pending recovery as an installed-and-ready result.
Interactive installation uses the same selected MSI without `/qn`.

Repair preserves a valid existing update setting. To explicitly change it while
reinstalling the registry component:

```powershell
$process = Start-Process msiexec.exe -ArgumentList @('/i', ('"' + $msi + '"'), 'REINSTALL=ALL', 'REINSTALLMODE=amus', 'GOMAPI_AUTO_UPDATE=0', '/qn', '/norestart', '/l*vx', 'C:\Install\go-mapi-repair.log') -Wait -PassThru
$process.ExitCode
```

Use `GOMAPI_AUTO_UPDATE=1` instead to enable it. Missing or invalid stored settings
require an explicit choice. A same-SKU upgrade preserves a valid choice.
To migrate system ↔ suite, an administrator installs the chosen destination MSI
with `GOMAPI_MIGRATE_SKU=1`. Do not deploy both products side by side or use this
flag for ordinary updates. See [MSI contracts](src/installer/msi/README.md) for
guards, rollback and lifecycle validation.

Uninstall the machine product through Installed apps or `msiexec /x` with its
selected MSI/product identity. The final-uninstall fence can refuse removal
while an interrupted update is unresolved. Preserve logs and follow recovery;
do not delete the service, protected state or pending transaction to bypass it.

Direct user-app installation uses the current-user NSIS installer; `/S` selects
silent installation in that user's context. It is not an all-users installer.
Normal app removal preserves user settings, queue and credentials. The direct
uninstaller's explicit purge choice removes user data; do not assume silent
removal purges it. Removing a user app does not uninstall the machine provider.

## Managed updates

The automatically started `go-mapi` LocalSystem service uses authenticated
metadata for the installed SKU, validates package identity, hashes and signing
trust, and launches a detached MSI update runner. It updates system or suite
without an administrator initiating each eligible same-SKU transaction.
Suite updates coordinate machine-app shutdown and launch admission; the suite
contains an all-users startup entry. The service does not change per-user packages,
settings, queues or Gmail credentials. Initial install, explicit repair and
SKU migration remain administrator operations.

Disabling automatic updates retains service health/status behavior. With trusted
release policy configured, the production startup check delay is two minutes,
the successful check interval is six hours and persistent failure delays are
bounded. CI's shortened validation timers are fixture-only; they are rejected
by release builds. Network failure does not prevent local service health.

The implementation and development-fixture CI cover real same-boot MSI updates.
This does not establish production endpoint operation or qualification of the
final signed release. Real reboot, no-interactive-user and multi-user execution
need their own observations; running a test as SYSTEM is insufficient.
See the [installed update gate](docs/component-integration-gate.md#installed-machine-update-gate).

## Files, identity and diagnostics

| Location | Purpose |
| --- | --- |
| `%ProgramFiles%\go-mapi\interceptor\AMD64` and `\x86` | Both native MAPI DLL architectures |
| `%ProgramFiles%\go-mapi\service` | Resident service binary |
| `%ProgramFiles%\go-mapi\user` | Suite app payload |
| `%ProgramData%\go-mapi` | Protected machine update/recovery state and public status |
| `%APPDATA%\go-mapi` | Each user's settings and app log |
| `%LOCALAPPDATA%\go-mapi\queue` | Each user's mail descriptors and owned attachments |

Credentials are per-user Windows Credential Manager entries. Keep user and
machine evidence separate; service execution does not authenticate a user to Gmail.
Machine MSI removal does not purge users' data or credentials.

In `%APPDATA%\go-mapi\settings.json`, `mode` is `manual` or `auto-draft`;
invalid values are reported as configuration errors. `autostart_enabled` records
the user's preference, subject to Windows policy. `update_checks_enabled=false`
disables the app's checks, independently of the machine MSI's
`GOMAPI_AUTO_UPDATE` setting. Prefer the app's settings UI for user changes.

Use the installed service state, MSI logs, update transaction logs under
`%ProgramData%\go-mapi\updates\logs`, and retained status when investigating failures.
Redact account/message data before sharing diagnostics. Simple MAPI registration
is distinct from MAILTO: current packages do not register a mailto-link handler
or change the user's Windows UserChoice association.

## Signing and deployment qualification

Verify a release's SHA-256 manifest and Authenticode signatures before deployment;
unsigned local artifacts and CI's disposable test certificates are not release
trust. Do not disable organization signing policy or trust a development root to
make a release package install. Azure Artifact Signing remains part of the
configured production signing path.

Test the selected package on the actual Windows versions, policy and user/session
contexts you deploy. Include a standard user's installed Send-To journey and
attachment draft, user state preservation, update/repair/uninstall and provider
restoration. The [email verification procedure](docs/email-integration-verification.md)
spells out these observations. Historical scheduled-session RAM measurements
are not present-day RDS/Citrix compatibility or updater qualification.

Store certification and winget catalog publication are separate external steps;
a submitted workflow is not proof the package is available to users. See
[Store](distribution/store/README.md) and [winget](distribution/winget/README.md).

For support use [GitHub Issues](https://github.com/marcfargas/go-mapi/issues).
For builds and verification entrypoints see [DEVELOPMENT.md](DEVELOPMENT.md).
