# Windows readiness and first commands

Start with the system `crabbox` and `crabbox-azure-leasing` skills. Source the
credential environment and use an explicit Azure provider, Windows normal
mode, `westeurope`, and `Standard_D2als_v7`; use an on-demand lease for a
repeatability run.

The first Windows readiness check is a short PowerShell probe over the
generated Crabbox SSH route, not `crabbox doctor` alone. A bare image can lack
Git even though PowerShell, OpenSSH, and Remote Desktop Services are already
working. Probe PowerShell, `sshd`, `TermService`, ports 22/2222/3389, Git, and
the effective elevation token. Bootstrap Git before asking Crabbox to sync.

Do not infer a sync or workspace-owner failure merely because `crabbox run`
has printed `provisioning` for a long time. First query the exact Azure VM and
`crabbox-bootstrap` extension. If both are `Succeeded`, use the generated key
for a direct PowerShell probe. A healthy probe before Crabbox prints
`provisioned` isolates the problem to the Azure create/bootstrap control path,
not the guest or sync protocol. Capture that distinction before retrying.

Use short checked-in PowerShell support files with `crabbox run --script` for
repeatable bootstrap and result markers; do not send a long encoded command.
Run bootstrap twice across a new connection. It must prove the required build
tools, Pester 5, and effective elevation, not just group membership.

## Buildchain bootstrap

A fresh image has Git but not Go, Node, Scoop, CMake/Ninja, NSIS, Wails, or
Pester. Run the bootstrap through Crabbox after the clean full sync, as an
administrator. Scoop must be invoked by downloading its installer to a file
and executing that file with `-RunAsAdmin`; piping it to `Invoke-Expression`
cannot pass that installer parameter.

Install and assert: Go `1.25.x`, Node `20.x`, `cmake`, `ninja`,
`mingw-mstorsjo-llvm-ucrt`, NSIS, WebView2 Evergreen runtime, Pester major 5,
and `wails@v2.12.0`. The MinGW package must expose both
`x86_64-w64-mingw32-clang++` and `i686-w64-mingw32-clang++`. Rebuild PATH from
Machine and User after Scoop changes. Do not run production Wails scripts that
require `.env.local`; fake-OAuth E2E uses its explicit fake credentials.

The blocking order is frontend `npm ci`/build/check/tests; Go vet and race
tests for `internal/mapi` and `src/app`; interceptor x64 Debug then x64/x86
Release CTest plus each matching harness; Wails build; NSIS plus installer
Pester; then RDPilot-driven WebView2 E2E. Existing CI's waived interceptor
harness result is not acceptable here.

Observed package corrections: Scoop's current `go` and `nodejs-lts` channels
can resolve newer major releases, so assert the repository-required major
versions rather than treating install success as compliance. The `extras`
bucket did not expose `webview2-runtime` on this image; install the Evergreen
runtime from Microsoft's official bootstrapper and verify its registry value.
PowerShell 5.1's bundled PowerShellGet can prompt while acquiring NuGet even
with `-Force`; bootstrap `Install-PackageProvider NuGet -Force
-Confirm:$false` before noninteractive Pester installation. On the observed
image, Pester 5 required `Install-Module ... -SkipPublisherCheck` because the
inbox Pester 3 package conflicts with gallery packaging. Do these as
separately recorded commands so a missing optional package does not hide
already-completed tools.

Do not use Scoop's floating `go` package for the Wails lane: it installed Go
1.27 and Wails v2.12.0 failed with `package "context" without types`. Install
the repository-pinned Go 1.25 release from `go.dev/dl` under a separate root,
set `GOROOT` and put its `bin` first for the build command. Scoop's Node
executable may also require adding
`$env:USERPROFILE\\scoop\\apps\\nodejs-lts\\current` explicitly, not only
the shim directory.

## Desktop inspection

Crabbox owns the desktop credentials for this lane. Do not ask the user for
RDP credentials, open public RDP, add NSG rules, or configure RDPilot against
the leased VM. Use Crabbox's managed desktop path instead. Wait several
minutes after desktop warmup before treating a desktop failure as meaningful.

For command-driven desktop validation, prove the selected launch mechanism
with a durable marker first. On the observed image, `crabbox desktop terminal`
opened Mintty but did not execute appended commands; `crabbox desktop launch`
successfully ran direct PowerShell in the managed desktop context. Persist
stdout/stderr and an explicit exit marker in a VM-local log (for example under
`C:\\ProgramData\\crabbox`), then retrieve it through a safe read-only path.
Do not rely on `desktop proof` when the guest lacks `scp.exe` or SFTP: proof
artifact collection can fail before it reports the command outcome.

The real keyring tests require the managed interactive desktop token;
SSH/WinRM fails with `ERROR_NO_SUCH_LOGON_SESSION` by design. Use the managed
desktop command path, with explicit `GOROOT`/`PATH` if the desktop shell does
not inherit Go. Capture a durable exit marker; an empty `cmdkey /list` after a
passing run is expected cleanup behavior.

## Sync and validation sequence

After the Git bootstrap, do one `crabbox run --full-resync --sync-only` using
the canonical lease ID. Treat success as unproven until a direct remote probe
records selected source hashes and the absence of ignored credential files.
When Git seed is enabled, also record HEAD and porcelain. A created remote
directory alone is not a completed sync.

If sync waits on a reusable-workspace owner or leaves an empty directory,
inspect the local Crabbox and SSH process tree plus the remote PowerShell
workspace-owner process before retrying. A binary stdin witness that has an
expected positive length but an on-VM `input` file of length zero is the known
native-Windows failure; verify direct SSH stdin separately, then use a
candidate with the input-bypass repair. Do not start a second sync while the
first client still owns that workspace. Record the fault and clean up the
owned VM if the transport cannot be recovered.

If an explicitly authorized full-resync still leaves only Git metadata or
omits current files, use a non-destructive fallback: transfer a ZIP or exact
files in conservative base64 chunks and write them with full-path Windows
PowerShell. In a local SSH chunk-reading loop, redirect each SSH invocation's
stdin from `/dev/null`, otherwise SSH can consume the next base64 chunk. The
observed guest lacked usable `scp.exe`, SFTP, and `tar`; do not assume those
utilities exist. Prefer per-file updates for a small delta and verify their
hashes before test execution. Do not test a desktop-token feature through SSH
simply because SSH was used for transport.

Then run the repository gates as evidence-bearing commands. Do not waive a
failure. The interceptor harness must load the built DLL of matching bitness,
exercise production's `%LOCALAPPDATA%` queue through `FsUtils`, use owned
attachment fixtures, and preserve pre-existing queue state. Require x64 Debug,
x64 Release, and x86 Release CTest runs before calling the interceptor lane
validated.
