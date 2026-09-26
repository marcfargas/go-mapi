# Component integration gate

The ordinary Playwright suite exercises the user component against an isolated
queue directory. Windows CI downloads the Release x86/x64 DLL and harness
artifacts, then invokes the checked-in component test against the real app
queue consumer. The test retains the native descriptor, app acknowledgement,
hashes and logs. It proves the component protocol, without claiming product
MAPI registration or Gmail delivery.

To repeat the same check on a disposable Windows machine, build or place the
independently selected artifacts, then run:

```powershell
just e2e-system-windows `
  -X64Dll src/interceptor/build-x64/bin/go-mapi.dll `
  -X64Harness src/interceptor/build-x64/bin/go-mapi-test-harness.exe `
  -X86Dll src/interceptor/build-x86/bin/go-mapi.dll `
  -X86Harness src/interceptor/build-x86/bin/go-mapi-test-harness.exe `
  -InterceptorVersion <interceptor-version> -AppVersion <app-version> `
  -EvidenceDirectory C:\ProgramData\go-mapi\component-integration
```

The harness explicitly loads each DLL. For each architecture it retains the
native `MAPISendMail` descriptor, runs the app-owned queue-consumer probe
against that exact file, and writes `component-integration.json`, the run log,
harness logs, and app acknowledgements. Missing evidence fails the gate.

## Installed machine update gate

The `admin-msi` job reuses those Release DLLs and the separately built machine
app. It prepares signed, disposable system A/B/C and suite A/B packages with
`just build-machine-test-packages`, runs the existing cross-SKU MSI lifecycle
script, and invokes `just machine-update-integration -Phase Hosted`. The
package manifest binds the source commit, explicit component version
substitutions, generated service versions, final signed MSI hashes and
deterministic MSI identities. The test certificates are generated on that
disposable runner only. The service build uses a localhost HTTPS origin and
the minimum supported 60-second check interval; production trust defaults
remain unchanged.

Run from an elevated, clean Windows machine with Go 1.25, .NET 8, WiX restore,
`llvm-rc`, `llvm-cvtres`, Windows SDK `signtool.exe`, the Release DLL artifacts,
and the unsigned machine app with its `app-artifacts.json`:

```powershell
$root = 'test-results/245-ci/local-run'
just build-machine-test-packages `
  -X64Dll <x64-dll> -X86Dll <x86-dll> `
  -MachineApp <go-mapi-machine.exe> -AppBuildManifest <app-artifacts.json> `
  -OutputDirectory release/machine-test -EvidenceDirectory "$root/build" `
  -MetadataOrigin https://localhost:18453 `
  -ArtifactOrigin https://localhost:18453/releases/download/
$packages = Get-Content "$root/build/machine-test-packages.json" -Raw | ConvertFrom-Json
& .\src\installer\msi\tests\CrossSkuLifecycle.Tests.ps1 `
  -SystemMsi $packages.packages.systemA.msi `
  -SuiteMsi $packages.packages.suiteA.msi `
  -NewerSuiteMsi $packages.packages.suiteB.msi `
  -LogDirectory "$root/cross-sku"
just machine-update-integration -PackageManifest "$root/build/machine-test-packages.json" `
  -EvidenceDirectory "$root/update" -Phase Hosted -FixturePort 18453
just machine-update-integration -PackageManifest "$root/build/machine-test-packages.json" `
  -EvidenceDirectory "$root/update-interruption" -Phase InterruptSameBoot `
  -FixturePort 18453 -DeadlineMinutes 22
```

Always run the owned cleanup after any failed native phase. Pass the interruption
evidence directory to both cleanup invocations, as CI does:

```powershell
just machine-update-integration -PackageManifest "$root/build/machine-test-packages.json" `
  -EvidenceDirectory "$root/update" -Phase Cleanup -FixturePort 18453 `
  -DeferredInterruptionEvidence "$root/update-interruption"
just machine-update-integration -PackageManifest "$root/build/machine-test-packages.json" `
  -EvidenceDirectory "$root/update-interruption" -Phase Cleanup -FixturePort 18453 `
  -DeferredInterruptionEvidence "$root/update-interruption"
```

`Hosted` bootstraps A explicitly through the administrator, then requires the
installed LocalSystem service to commit B and C itself. It observes the real
artifact GET and a failed install attempt while C's code-signing trust is
removed, restores only that owned trust, and waits for C to commit. It then
disables automatic update through the supported administrator repair and
checks a complete startup and cadence window without metadata or artifact
requests. A second CI invocation runs `InterruptSameBoot` with the same signed
packages after the Hosted phase has cleaned its install. It imports only the
manifest-matching public fixture certificate to restore Windows trust,
requires matching pending and ready records plus live runner/MSI identities,
terminates that exact runner, and checks conservative same-boot state. A missed
observation fails CI. The real MSI lifecycle script covers cross-SKU migration, repair,
rollback, settings, legacy task retirement and final uninstall. The hosted
gate fails on an unobserved transition, and uploads its build, request, MSI,
status and cleanup evidence even after a failure.

An exact same-boot runner interruption can leave a healthy B installed with
`outcome-unconfirmed` pending and no replay commitment. The product's final
uninstall fence correctly refuses removal until a changed boot resolves that
transaction. In this one case the hosted job requires the MSI fence's 1603
log and matching manifest, product and transaction identities, removes its
HTTPS binding and test certificates, and records `cleanup-deferred.json`.
Both CI cleanup calls validate that evidence. The installed test product and
pending record then remain on the disposable GitHub-hosted runner until GitHub
disposes of the machine. A normal Hosted run removes its installed product;
any other cleanup failure still fails CI. A reusable Windows machine needs a
real reboot and postboot reconciliation before its operator can uninstall the
product; the deferral record is not clean-machine proof.

The same runner exposes `PrepareNoUser`/`VerifyNoUser` and
`PrepareReboot`/`VerifyReboot` phases for an external
Windows orchestrator. `PrepareNoUser` leaves A installed with an A target;
`VerifyNoUser` checks that there is no interactive session before publishing B,
then observes B and C commits without one. `PrepareReboot` interrupts an exact
live B runner and requests an immediate Windows reboot. The startup fixture
captures the matching pending record under the new boot identity before
`VerifyReboot` accepts B recovery and observes C. A missed startup capture
fails rather than becoming postboot proof.
These phases
are executable but are **not wired to hosted GitHub Actions**: GitHub's runner
session and job lifecycle cannot establish no-user or reboot proof, and this
repository has no unattended remote orchestration connection. A disposable
VM operator must export the ignored `test-results/245-ci` evidence before
releasing the machine. Prior manual native evidence remains historical and
does not attest to a run of these new scripts.

The CI certificate establishes development behavior only. An actual release
still requires Azure signing and verification bound to the exact final MSI
and required executable bytes; the CI fixture is never a production signer.
