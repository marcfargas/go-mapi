# Installed suite attachment transaction

This directory contains the installed-MSI test oracle and its failure-safe
transaction runner. It invokes the installed app without arguments and loads
the x64 Simple MAPI DLL from the suite installation. The fake accepts only
loopback CONNECT traffic for `www.googleapis.com:443`; it never forwards a
request. The generated bearer token, message, attachments, test trust and
profile are synthetic and disposable.

The Go helper, Python runner and PowerShell scripts are repository/CI test
assets. They are outside the suite MSI payload.

## Requirements

- The project-owned CrabBox ready-handoff lease selected for this run, with a
  Windows Server 2022 small-disk Gen2 guest, one non-admin interactive user,
  an SSH handoff, loopback RDP tunnel, and the original 0600 password file.
- Host tools `crabbox-handoff`, `rdpilot`, `ssh`, Python 3.11 or later and Go
  1.25 or later. The runner uses the persistent `rdpilot-mcp --session NAME`
  interface and checks every call against the schemas returned by that server.
- Immutable suite alpha.7 and alpha.10 MSI files, their app/DLL hashes from
  their signed package manifests, and a pinned Microsoft WebView bootstrapper
  with its vendor hash. The setup transaction verifies signatures and hashes,
  disables auto-update, and checks installed bytes before each run.
- A clean checkout at the exact `--source-sha`. CI must pass for that exact
  commit before immutable package publication.

The transaction uses one disposable standard-user profile for all cases. It
first installs alpha.7, proves the profile unloaded, converts that profile to
an actual VHD volume mount point, runs the alpha.7 expected-rejection case,
upgrades in place to alpha.10, runs the fixed VHD case, restores the original
normal profile, and runs the fixed normal case. The CUA session is disconnected
before each profile logoff; the runner observes the exact SID/session, proves
the profile and registry hive unloaded, and reconnects with the original
password file through `PasswordCommand="cat FILE"`. It never copies the
password into arguments or evidence. The run-specific CA trust prompt must be
confirmed from screenshot/UIA evidence; an unrecognized dialog fails the run.

## Build the test helper

Build the standard-library-only helper for Windows x64 from this checkout and
stage it beside the case artifacts:

```powershell
$env:GOWORK = 'off'
$env:GOOS = 'windows'
$env:GOARCH = 'amd64'
go build -trimpath -o C:\crabbox\work\installed-attachment\fake-gmail.exe ./tests/installed-attachment/fake-gmail
```

Keep the output and run evidence outside the MSI payload. Retain the helper's
source SHA and hash with the case.

## Run the complete matrix

From the clean source checkout, invoke one host command. Obtain MSI and
bootstrapper hashes from the selected immutable manifests; keep the handoff
status file and its password/key files in the private CrabBox-owned paths:

```powershell
python tests/installed-attachment/run.py `
  --backend crabbox-matrix `
  --source-sha <exact-clean-source-sha> `
  --evidence-dir C:\crabbox\owner-evidence\ticket569-<unique-id> `
  --handoff-status <selected-ready-handoff-status.json> `
  --cua-session ticket569-<unique-id> `
  --rdp-port <loopback-rdp-tunnel-port> `
  --baseline-msi <immutable-suite-v3.2.0-alpha.7.msi> `
  --baseline-msi-sha256 <alpha.7-msi-sha256> `
  --baseline-app-sha256 <alpha.7-installed-app-sha256> `
  --baseline-dll-sha256 <alpha.7-x64-dll-sha256> `
  --candidate-msi <immutable-suite-v3.2.0-alpha.10.msi> `
  --candidate-msi-sha256 <alpha.10-msi-sha256> `
  --candidate-app-sha256 <alpha.10-installed-app-sha256> `
  --candidate-dll-sha256 <alpha.10-x64-dll-sha256> `
  --webview-bootstrapper <pinned-microsoft-webview-bootstrapper.exe> `
  --webview-sha256 <webview-sha256>
```

The runner creates unique case IDs and output directories under the isolated
guest work root. A failed run still attempts profile restoration and downloads
the guest evidence tree; restoration, disconnect, or evidence collection errors
are latched into `cleanup.json` and make the host command fail. The top-level
`matrix-final.json` is emitted only for the verified three-case matrix.

The normal fixed run and VHD fixed run use the same message subject and exact
two attachment byte hashes. The harness records actual profile/SID/session,
the exact owned VHD image behind a mounted profile, installed executable and
DLL hashes, caller native return, transaction-child exit, and the CUA-launched
launcher exit captured through a separately attached Windows process handle.
Direct-mode reports name the waited PowerShell process `interactiveLauncherExit`;
the outer `run.py` entrypoint exit remains the invoking tool's process receipt.
Queue evidence must show the same entry created and deleted before the app is stopped;
final fake counters, queue inventory and cleanup status are also retained.
The fake is stopped only after the installed app process is stopped and
waited; it then drains accepted requests for a bounded interval and atomically
writes one final snapshot. Missing or malformed output, late duplicates,
rejected requests, failed writes, timeouts, nonzero children and cleanup
failures cannot be reported as a pass.

## Portable failure-contract checks

From the repository root:

```powershell
$env:GOWORK = 'off'
go test -C tests/installed-attachment/fake-gmail -count=1
python -m unittest discover -s tests/installed-attachment -p 'test_*.py' -v
powershell.exe -NoProfile -NonInteractive -File tests/installed-attachment/process-observer-check.ps1
```

The process-observer check runs a real local PowerShell child that exits with
code 7, then verifies successful handle attachment, handle-derived creation
identity against the CIM identity, missing-process rejection, and bounded-timeout
failure. Observer attachment has a 30-second bound; its retained-handle wait
uses the full configured case lifetime plus an attachment allowance, so the
historical 90-second alpha.7 failure remains observable. It needs Windows but
no CrabBox lease or GUI.

The hosted capability workflow is a one-shot first-creation push on
`t3code/569-reviewed-preflight-20261009`. It checks out and passes that event's
immutable `github.sha`. The no-MSI preflight builds the client, daemon, MCP
server and bridge from rdpilot commit
`8f799dd1e37422a8966833a08e4ec279f645ec58` outside the go-mapi checkout. Its
loopback RDP connection uses the disposable non-admin user's credentials only
through a private `PasswordCommand` environment and an isolated runtime.
Native MCP UI Automation must identify the unique test-certificate subject and
Root-store consent prompt in that exact user session before the bounded `y`
answer is sent. The preflight independently verifies that the exact certificate
appeared and was removed from `CurrentUser/Root`; it never imports an MSI or
substitutes machine-wide trust. Missing, ambiguous or unanswered prompts remain
unknown/harness failures and cannot establish hosted unavailability.

The same bounded preflight measures actual-user sign-in and normal/VHD profile
capability, then restores the disposable user and profile. It retains atomic
child and final parent evidence, PID/creation/exit proofs, and guarded VHD
restoration. A decisive normal-route limitation and a VHD-only limitation are
reported separately. This hosted job does not run an installed-MSI case and
does not itself establish the later candidate signing window or hosted package
acceptance.

Push CI checks the source commit with Windows-hosted PowerShell parsing and
runs the portable failure-contract suites from that exact commit. Those CI
checks do not establish an interactive session or mounted profile; only the
one-shot hosted preflight observes those capabilities.
