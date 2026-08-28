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

Use `rdpilot` for Windows desktop work. Azure Windows has an RDP listener and
Remote Desktop firewall rules on the guest; do not use Crabbox's VNC screenshot
path as the desktop readiness test. First inspect the NSG. If its current rules
do not expose TCP 3389, add a temporary rule restricted to the current host's
single public `/32`, then remove that exact rule during cleanup. Connect with a
self-owned RDPilot session name, perceive the desktop before input, and always
disconnect explicitly.

Use the interactive RDP session for WebView2/Wails E2E. A checked-in desktop
wrapper must write an exit marker that SSH-side polling can read, so a detached
desktop launch becomes a bounded test result.

RDPilot deploys its configured local sensor through its RDPDR `RDPILOT` drive;
do not copy it through SSH. When bootstrap fails, diagnose the actual remote
interactive session with PowerShell: confirm `fDisableCdm=0`, inspect the
interactive user's `%TEMP%` for the copied executable, inspect its `cmd.exe`
command line, and check Defender/CodeIntegrity events. The bootstrap command
must remain below the Windows Run/ShellExecute 260-character limit after
environment-variable expansion. On Crabbox profiles the original command can
lose the final two characters, preventing launch even though RDP and RDPDR are
healthy. Fix and test that command in RDPilot before treating the VM as a
sensor or keyring failure.

The two real keyring tests require an RDP RemoteInteractive credential set;
SSH/WinRM fails with `ERROR_NO_SUCH_LOGON_SESSION` by design. Compile the test
binary via the SSH lane, run only those tests inside RDPilot, capture a durable
exit marker, and confirm `cmdkey /list` contains no leftover `go-mapi` target.

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

Then run the repository gates as evidence-bearing commands. Do not waive a
failure. The interceptor harness must load the built DLL of matching bitness,
exercise production's `%LOCALAPPDATA%` queue through `FsUtils`, use owned
attachment fixtures, and preserve pre-existing queue state. Require x64 Debug,
x64 Release, and x86 Release CTest runs before calling the interceptor lane
validated.
