# Local Windows development

Use the Windows host for compilation and frontend feedback, and a disposable
Windows Sandbox for service, registration, certificate and installer effects.
The commands below target the current split user app and system component.

## Local CI

Use `just ci` for Windows development feedback. The Just recipe supplies
`act -P windows-latest=-self-hosted` and selects the host-only check job;
`just ci-plan` lists its selected job without executing it. Install act with
`just setup-act`, then open a fresh shell to refresh PATH.
The runner mapping executes on the current machine and provides no isolation.
DLL execution/registration, service tests, signing fixtures and MSI installation
use the disposable Sandbox commands below. GitHub workflows invoke the same
leaf Just commands and shared GitHub actions; signing and publication retain
their real hosted environment. `just package-user` selects the unsigned standalone
leg of the app packaging job and prints its retained artifact directory under
`release/act/`. It rebuilds the app inside act's workspace instead of depending on
ignored host outputs. `just ci-plan app-packages` lists that job.

## Install tools

Scoop is preferred. Open a fresh PowerShell after installing tools so its PATH
includes the new directories.

```powershell
scoop install go cmake ninja just uv mingw-mstorsjo-llvm-ucrt windows-sdk-buildtools
scoop bucket add extras
scoop install nsis@3.11
scoop bucket add versions
scoop install versions/dotnet8-sdk
scoop install versions/nodejs20

# Scoop's current Go may be newer than the qualified Wails toolchain.
$env:GOTOOLCHAIN = 'go1.25.14'
go version
go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0
npm ci
npx playwright install chromium
```

The project qualifies Go 1.25.x, Wails 2.12.0, NSIS 3.11 and .NET 8. WiX 4.0.5
is restored by the MSI projects; a global WiX installation is unnecessary.
Node 20 is used by CI and by the qualified local setup. The box's preinstalled
Node 26 failed the Vitest localStorage setup; use Node 20 for this checkout.
Scoop can keep both versions installed. Verify `node --version` in the build
shell. Do not change the dependency lockfile merely to set up the box.

Install developer tools explicitly as above, open a fresh shell, then check Go
and Node:

```powershell
$env:GOTOOLCHAIN = 'go1.25.14'
just doctor-windows
```

GitHub runner setup belongs to the shared `setup-windows` action. Local act
packaging checks and resolves already installed tools; it does not install them.
Scoop's SDK buildtools package supplies
`makeappx.exe` and `signtool.exe` without the full Visual Studio installation.

## Host feedback

```powershell
just test-user
just check-user
just e2e-user
just build-service-windows .tmp/go-mapi-service.exe
just build-service-tests
just test-windows-tooling

# Compile both native architectures, including their test binaries.
just build-native-tests x64
just build-native-tests x86
```

`just test-system` runs CTest, including a harness that writes to the canonical
queue. Run that execution in the guest. On Windows, the broader
`just test-windows` and `just check-portable` recipes also execute service tests;
their fixture can create a machine service. Use the guest for those recipes.
Serialize frontend/Wails build recipes within one checkout: Vite replaces
`frontend/dist`, which Go embeds. Concurrent builds can temporarily remove those
inputs and cause a misleading embed failure.
Use a checkout path without spaces for native builds. The current GNU linker
`--output-def` argument is unquoted; an alternate checkout containing spaces
failed during local setup. The selected development checkout has no spaces.

For a development app build, supply the OAuth variables privately through the
existing `.env.local` or environment mechanism and run `just build-user`.
Without real credentials, explicit non-secret fixture values can prove
compilation; that binary cannot authenticate and is not shippable. Never publish
fixture credentials or infer real OAuth acceptance from a compile.
Release-mode builds also require `GOMAPI_ADMIN_RELEASE_METADATA_URL` to be a
bare HTTPS origin without a path, credentials, query or fragment. The App
queries its `/machine/system/targets.json` endpoint. For disposable package
fixtures use the origin selected by the machine test scripts; do not embed that
origin in a distributable release.

`just package-user` runs CI's unsigned MSIX/NSIS validation with explicit fixture
credentials and the source version; these packages are not release artifacts. Real user
releases use the unified release workflow's tag/version, signing and publication gates.
The shared `package-user` action packages the selected EXE and build manifest;
its identity and version inputs do not depend on a mutable checkout version.
`just package-system` and `just package-suite` build machine packages from explicit
input manifests. Read component READMEs for those contracts. The retired combined
installer and Inno/native-host flow are not current verification paths.

## Windows Sandbox and Crabbox

Install the complete matching Windows archive from
[Crabbox releases](https://github.com/openclaw/crabbox/releases), verify its
published SHA-256 and keep `crabbox-runtime` beside `crabbox.exe`.
Crabbox is not currently in the standard Scoop buckets checked during setup.
Its [Windows Sandbox provider](https://github.com/openclaw/crabbox/blob/main/docs/providers/windows-sandbox.md)
uses local Windows compute, without Azure credentials or an SSH/rsync transport.
The repository's `.crabbox.yaml` selects it by default.

In an interactive desktop PowerShell:

```powershell
crabbox doctor --provider windows-sandbox
crabbox run -- powershell -NoProfile -Command "Write-Host ok"
```

Windows Sandbox requires an enabled feature, virtualization and a usable desktop
session. On this box, Sandbox 0.8.107.0 crashes when launched from service session
0; the same command succeeds from the existing logged-on desktop session.
An authorized agent in session 0 can run a temporary scheduled task using that
user's existing interactive token, collect logs and exit status, and unregister
the task. No password or new logon is needed. A disconnected desktop session
still differs from service session 0.

Crabbox 0.80.0 can report unconfirmed viewer ownership after the guest shuts down.
Preserve its run directory and verify cleanup; do not kill Sandbox processes by
name. Do not launch another test while an unrelated Sandbox is running.
Use `just sandbox-smoke`, `just prepare-native-inputs` and `just sandbox-test`
through the [Sandbox procedure](../tests/sandbox/README.md). The native runner is
a bounded workaround until Crabbox demonstrates equivalent isolation, SYSTEM
execution, evidence and owned cleanup. Its implementation and behavioral checks
live together in `tests/sandbox/`.

Build machine signing fixtures inside the guest: the fixture builder creates
machine certificates and imports trust before it builds packages. Keep manifests
and artifacts at the paths recorded inside that guest. A T3 worktree's `.git`
file points outside the checkout; mapping only the worktree does not create a
usable guest Git repository. Use an independent disposable clone/archive with
explicit source identity and record relevant dirty input changes.

## Evidence and limits

Keep a unique run directory under ignored `test-results/`; retain unique evidence
under `$env:LOCALAPPDATA/agent-work/retained/go-mapi/<task>` when it must outlive
scratch cleanup. Record source revision, dirty input changes, tool versions,
artifact hashes, commands, results and exact cleanup. Export guest evidence before
discarding it, including failure logs.

Same-boot Sandbox testing does not establish actual reboot/postboot, no-user,
RDS/multi-user, live Gmail, native desktop or Store acceptance. Follow
[the component gate](component-integration-gate.md) and
[installed email verification](email-integration-verification.md) for those
boundaries. Existing release signing and required CI gates remain separate.

Project agent procedures live under `.agents/skills`: `go-mapi-capture`,
`go-mapi-docs`, `go-mapi-verification` and `go-mapi-crabbox-build`. Claude
entrypoints under `.claude/skills` point to the same maintained source using
ordinary files so Windows checkout and Crabbox sync require no symlinks.
Restart/refresh the target host to test its native skill catalog; source presence
alone does not prove automatic selection.

## Command ownership

Just owns development commands. GitHub workflows call those commands and own
runner provisioning, dependencies, artifact transport, signing and publication.
The local `just ci` wrapper fixes the Windows runner mapping and defaults to
`windows-check`. `just package-user` selects unsigned standalone packaging using
the source version. Other job names are refused. act does not supply
an isolated runner image, enforce GitHub release permissions or reproduce OIDC.
The other Windows jobs reject act before machine-changing work.

Build and package implementations live beside their components: app commands in
`src/app`, machine packaging and lifecycle tests in `src/installer/msi`, signing
support in `distribution/signing`, and desktop/performance probes in `tests`.
`just test-windows-tooling`, `just test-msi-tooling` and
`just test-attachment-tooling` exercise these owners without installing the product.
The removed `scripts/` directory has no replacement general-purpose script area.
Existing immutable app manifests retain explicit compatibility with their original
builder identifiers; new manifests identify the public Just command.

The default [Windows e2e suite](component-integration-gate.md) installs the
selected Suite in a fresh Sandbox and includes the real Explorer SendTo journey
before x86/x64 queue integration. It builds its fake/probe locally. Hosted CI's
explicit `-ComponentOnly` mode covers queue integration without desktop acceptance.
The lower-level [installed attachment smoke](../tests/installed-attachment/README.md)
uses the guest's existing non-elevated desktop user and an already-installed suite.
It creates no accounts, migrates no profiles and provisions no virtual disks.
Focused Go path tests retain junction handling and escape rejection; the optional
real-volume test is separate from ordinary release acceptance. Historical alpha.7
transport/signature and alpha.9 incident machinery are retired. Current tooling
contracts do not establish a fresh installed smoke pass.
