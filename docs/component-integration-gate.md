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

Ordinary pushes and pull requests run `just check-portable` on Ubuntu and
`just test-windows` on Windows. `check-portable` runs Go tests and vet for
internal/app/service, frontend Vitest/Svelte checks, and fake-backend Playwright
queue/auth tests. Playwright failure reports and traces are retained. The
Windows service-package tests need an elevated process. Their package fixture
borrows an existing `go-mapi` SCM registration unchanged, or creates a disabled
`go-mapi` entry only when the name is absent. It never starts the entry and
removes only one it created. The fixture enables the test process's
`SeRestorePrivilege` when needed and restores its previous state so the tests
exercise the real SYSTEM-owned storage ACL implementation. Forced termination
can bypass cleanup and leave a disabled `go-mapi` entry; inspect its identity
before any manual removal. These elevated tests do not prove ordinary-user or
service-logon authorization.

The Windows native matrix runs `just test-system <x64|x86> <Debug|Release>` for
all four combinations; that command builds and runs the matching harness and CTest
suite, and CTest fails if no tests are registered. The Release DLL and harness
artifacts feed the separate queue integration command above. `just
prepare-windows -Native -Wails -Packages -Install` prepares pinned Windows
prerequisites as needed; omit `-Install` to validate an existing environment.

The user Windows job builds a release standalone app at 5.0.1-alpha.4 with
`just build-user-release -OutputDirectory ci-input/app-standalone` and verifies
its EXE and manifest. It makes the MSIX and NSIS package from that exact EXE
while `src/app/VERSION` still names A. It then builds the machine app A and
suite app-only C separately with `just build-user-machine -OutputDirectory
ci-input/appA` and `ci-input/appC`; C uses 5.0.2-alpha.1. Each EXE and manifest
pair is verified before upload. The job repeats these three builds and checks
on the same checkout to exercise owned-output replacement, without rebuilding
the user packages. The first verified pairs are the uploaded handoff artifacts.

The `admin-msi` job reuses the Release DLLs and distinct A/C machine apps. It
prepares disposable signed system A/B/C and suite A/B/C packages with `just
build-machine-test-packages`. Suite C keeps B's exact service and interceptor
bytes and source identities while changing the app. The signed-input writer is
shared with machine release validation, but these fixture certificates are
local to a disposable runner and have no Azure timestamp or release authority.
The manifest binds the source commit, explicit version substitutions, signed
PE and MSI hashes, and deterministic MSI identities. The service uses a
localhost HTTPS origin and the minimum supported 60-second check interval.

Run the installed gate only on an elevated, clean, disposable Windows machine
with Go 1.25, .NET 8, WiX restore, Windows SDK signing tools, the Release DLLs,
and the A/C machine app EXE and manifest pairs:

```powershell
$root = 'test-results/245-ci/local-run'
just prepare-windows -Native -Install
just build-machine-test-packages `
  -X64Dll <x64-dll> -X86Dll <x86-dll> `
  -MachineApp <app-A.exe> -AppBuildManifest <app-A-artifacts.json> `
  -SuiteCApp <app-C.exe> -SuiteCAppBuildManifest <app-C-artifacts.json> `
  -OutputDirectory release/machine-test -EvidenceDirectory "$root/build" `
  -MetadataOrigin https://localhost:18453 `
  -ArtifactOrigin https://localhost:18453/releases/download/
just machine-hosted-integration `
  -PackageManifest "$root/build/machine-test-packages.json" `
  -EvidenceDirectory $root -FixturePort 18453
```

The hosted command runs cross-SKU lifecycle, system Hosted, suite Hosted,
suite Cleanup, then system InterruptSameBoot with a 22-minute deadline. It
checks phase result files and attempts all applicable cleanup while retaining
both primary and cleanup failures. The workflow invokes the same command with
`-CleanupOnly` in an `always()` step after fixture preparation, and always
uploads build, MSI, request, status, event and cleanup evidence. When
`cleanup-deferred.json` exists, cleanup targets only system update and
interruption with the deferred evidence; the phase script still checks the
observed uninstall fence and exact interrupted identity. A deferred product
is reported separately from a clean machine.

The small `pwsh -File scripts/tests/BuildCi.Tests.ps1` command checks build
state and failure contracts with stand-ins. It does not prove that a PE builds
or installs. Hosted Windows jobs provide that proof for the disposable inputs.

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
The hosted cleanup phase validates that evidence. The installed test product and
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
Final Azure-signed shipped-byte installation, real reboot/no-user/RDS or
multi-user behavior, live Gmail/OAuth delivery, Store installation and complete
real desktop shell E2E remain separate proof gaps.
