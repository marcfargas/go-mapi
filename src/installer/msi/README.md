# go-mapi machine MSIs

`Package.wxs` and `SuitePackage.wxs` define separate, mutually exclusive
system-only and suite products. `MachinePackage.wxi` supplies their common
transaction behavior; `SharedMachine.wxs` supplies one interceptor and resident
service. The suite alone installs the all-users app in Program Files, a common
Start Menu shortcut, and an HKLM Run entry. Neither product inventories or
changes per-user packages, settings, queues, or credentials.

Both products require elevated Windows Installer transactions with rollback
enabled. An immediate guard runs after `InstallValidate`, before the
auto-update choice, transaction initialization, old-product removal, and
custom-action journals. It checks machine-context MSI products under the two
fixed UpgradeCodes. Ordinary repair rejects a foreign product; an initial
cross-SKU migration needs `GOMAPI_MIGRATE_SKU=1` and an exact foreign removal
list. A matching existing `AutoUpdateEnabled` DWORD is preserved unless an
administrator supplies `GOMAPI_AUTO_UPDATE=0` or `1`.

`build.ps1` accepts a `go-mapi-machine-signed-input-v1` manifest containing
the exact component binaries, versions, architectures, and hashes. Suite
inputs also require `appBuild` evidence linked to the machine app's
`app-artifacts.json` (or public `machine-app-artifacts.json`): source commit,
controlled build invocation, tool versions, unsigned hash, and signed binary
metadata. The package release version is separate from the contained component
versions. Use `-RequireSignedInputs` for trusted release inputs. The nonpublishing
CI fixture job may build unsigned artifacts for native test only.
Build from a Git checkout or a source archive whose commit and archive hash
were verified before extraction. Pass that commit through `-SourceCommit` when
the archive has no `.git`. The App's `build.ps1` records the commit and finished app
artifact digest; `build.ps1` checks the app commit against the machine input
manifest before packaging.

Public releases use one `v<package-release>` tag. App and Suite advance together;
System can skip release numbers. Suite may contain exact signed service and DLL
bytes from an earlier published System while retaining its own new package
identity. The signed-input manifest describes assembly source and component
hashes; release validation provenance records each component's original source
and the selected System tag/proof. Reuse requires unchanged machine installer and
build inputs as well as matching binary hashes. See the
[release procedure](../../../DEVELOPMENT.md#package-and-release).

On disposable elevated Windows, run the compiled table verifier for each MSI:

```powershell
.\src\installer\msi\verify.ps1 -SKU system -PackageRelease <system-release> -MsiPath <system.msi>
.\src\installer\msi\verify.ps1 -SKU suite -PackageRelease <suite-release> -MsiPath <suite.msi>
.\src\installer\msi\tests\CrossSkuLifecycle.Tests.ps1 -SystemMsi <system.msi> -SuiteMsi <suite-S1.msi> -NewerSuiteMsi <suite-S2.msi> -NewerAppSuiteMsi <suite-S3.msi> -LogDirectory <private-log-dir>
```

`suite-S3.msi` contains a different app file than `suite-S1.msi`, so that
upgrade replaces a running `go-mapi.exe`.

The lifecycle driver checks manual install, repair, same-SKU upgrade, both
explicit migration directions, rejection and rollback paths, and final
uninstall. Exit 3010 is a reboot checkpoint requiring the same guest's postboot
inspection. Interactive standard-user app, MAPI, ACL, and per-user package
preservation checks require separate native evidence. For implemented
service-driven system/suite update scenarios and their evidence
boundaries, follow the [installed update gate](../../../docs/component-integration-gate.md#installed-machine-update-gate).
