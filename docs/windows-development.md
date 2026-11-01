# Local Windows development

Use the Windows host for compilation and frontend feedback, and a disposable
Windows Sandbox for service, registration, certificate and installer effects.
The commands below target the current split user app and system component.

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

From the shell that will run builds:

```powershell
$env:GOTOOLCHAIN = 'go1.25.14'
. ./scripts/prepare-windows-build.ps1 -Native -Wails -Packages -Msi
```

Dot-sourcing retains process-local PATH changes. `just prepare-windows` checks
tools in a child process; its PATH changes cannot update the calling shell.
`-Install` supports only the tools documented by the preparer; it is not an
installer for every prerequisite. Scoop's SDK buildtools package supplies
`makeappx.exe` and `signtool.exe` without the full Visual Studio installation.

## Host feedback

```powershell
just test-user
just check-user
just e2e-user
just build-service-windows .tmp/go-mapi-service.exe
go test -c -o .tmp/service.test.exe ./src/service
just test-windows-tooling

# Compile both native architectures, including their test binaries.
pwsh -NoProfile -File src/interceptor/build.ps1 -Arch x64 -Config Release -Tests
pwsh -NoProfile -File src/interceptor/build.ps1 -Arch x86 -Config Release -Tests
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
Release-mode builds also require `GOMAPI_ADMIN_RELEASE_METADATA_URL` to be an
HTTPS URL. For disposable package fixtures use the fixture origin selected by
the machine test scripts; do not embed that origin in a distributable release.

Current package commands are `just package-user-standalone`,
`just package-user-msix`, `just package-system` and `just package-suite`.
Read their script parameters and component READMEs for required artifact/version
manifests. The retired combined installer and Inno/native-host flow are not
current verification paths.

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
execution, evidence and owned cleanup. Host orchestration belongs in `scripts/`,
its contracts in `scripts/tests/`, and guest checks in `tests/sandbox/`.

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
