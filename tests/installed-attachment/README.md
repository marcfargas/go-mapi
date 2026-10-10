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
`t3code/569-bounded-preflight-20261009`. It checks out and passes that event's
immutable `github.sha`. The no-MSI preflight builds the client, daemon, MCP
server and bridge binaries from rdpilot commit
`8f799dd1e37422a8966833a08e4ec279f645ec58` outside the go-mapi checkout. Its
loopback RDP connection uses the disposable non-admin user's credentials only
through the worker-to-owner control pipe and a bounded CurrentUser-only
one-shot pipe from the owner to the exact pinned `rdpilot` `PasswordCommand`
child. The password never enters a process environment, command line or file.
Native MCP UI Automation must identify the unique test-certificate subject and
Root-store consent prompt in that exact user session before clicking its
identity-bound affirmative UIA control. The preflight independently verifies that the exact certificate
appeared and was removed from `CurrentUser/Root`; it never imports an MSI or
substitutes machine-wide trust. Missing, ambiguous or unanswered prompts remain
unknown/harness failures and cannot establish hosted unavailability.

Before the session owner starts, the bounded CUA build stage downloads only the
audited `nightly-cua-driver-rs-v0.30.5-nightly.20260929.36522098176` Windows
archive, enforces a 60-second and exact-byte-count limit, and checks its fixed
SHA-256. It copies the bridge just built from the pinned rdpilot source into
that same bundle and records both file hashes. The session owner supplies the supported process-local `RDPILOT_BUNDLE_PATH`
override to the CLI, daemon and MCP, and retains a private configuration copy; its per-login hosts file pins that exact CUA release and sets
`CuaAutoDownload no`. Thus the daemon has the locally built bridge and exact
verified archive available without its dynamic download defaults. The source
and release input are pinned, but runtime compatibility of those guest
components remains unrun and is not claimed by local tests.

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

The hosted owner stops and flushes its retained prompt service before each
planned disconnect and remains available for the second planned login. Unexpected
stream loss stays fatal. Consent screenshots use immutable content-addressed
filenames. Helpers wait for exact identity gates before mutation and retain their
process handles through result writes and the finishing hold. Windows PowerShell
5.1 remains the importer and recovery participant runtime.

Recovery on the retained second login may attach a removal-only MCP watcher
after the prior planned service stop. It rechecks the owned SID, session, loaded
profile and volume, then uses the existing bridge; it never reconnects or replays
the import. Unavailable identity or an unexpected stream loss remains unverified.

The absolute cutoffs are J+21 for work, J+24 for cleanup, J+25 for local final
evidence/watchdog, and J+27 for upload. Failure evidence can still be retained
after a missed local-final cutoff, with failure qualification and a verified
complete-set index and secret scan. A retained upload Job Object limits the actual
node20 upload child to at most two minutes or the remaining seconds, including
subminute attempts. Successful upload exit remains attempted-unverified until
the root independently audits the downloaded artifact. Runner cache integration
and Windows kernel behavior require Windows CI; portable arithmetic is insufficient.
The cached upload entry receives explicit upstream defaults: overwrite false,
hidden files excluded, and compression level 6. CI checks the production wrapper
environment against the hash-pinned upstream compiled input parser with action
startup and networking suppressed; this does not prove artifact retention.

`profile.ps1` defaults to the lease interface used by the SSH runner. Hosted
callers explicitly supply the sole-writer mutation hook and absolute deadline.
The VHD route can produce a typed limitation only for actual CredWriteW
ERROR_NOT_SUPPORTED (50), verified mounted-profile identity, a feasible normal
control, and verified credential absence without cleanup errors. Other native
errors, helper failures and unknowns remain failures. This describes the observed
API refusal and does not claim a general Windows VHD limitation.


The ordinary fixture gives all three credential-launched PowerShell 5.1 paths
one atomically created run-private compiler directory below ProgramData. Its
protected DACL grants exactly the runner, SYSTEM and target SID; source/owner,
ancestry, reparse and collision guards run before launch and owned removal.
The actual parent cmdlet metadata selects per-child `Start-Process -Environment`
when supported; the fallback restores process TEMP/TMP in nested `finally`,
including unset values. Descendants inherit the path. CI requires observed
compiler-directory absence; extracted fault tests adapt Windows creation and
DACL observations and do not prove actual Windows compilation or ACLs.

Ordinary CI creates no Root certificate. Its account-created launcher/recovery
worker reads the exact run subject in band and rejects any ownership or mutation
request, retaining an empty removed-thumbprint list, subject absence, CredRead
1168, exit 0 and an empty Job. Its health response is a **synthetic protocol
adapter (`fixture-no-CUA`)**, not evidence of a healthy owned desktop. The separate
actual `RemoveOwned` already-absent CLI uses a **simulated ledger import attempt**
(sequences 1/2); no import or native certificate deletion occurred.

| Ordinary CI proof | Qualification |
|---|---|
| Framework/pwsh Job, process, gate and protected helper pipe APIs | Actual Windows kernel/runtime checks |
| Empty-store nonadmin launcher/recovery and profile/account/hive absence | Actual Windows account and readbacks; synthetic health protocol only; recovery removal loop runs zero times |
| Direct `RemoveOwned` already-absent CLI | Actual Windows interface/readback; simulated ledger, no import/deletion |
| Present-owned removal and recovery loop fault suite | Extracted production try/catch/final pass/exit mapping and loop; real in-process helper mutation pipe; store/identity/process/health adapters, no native deletion |
| Native present-certificate `RemoveOwned` recovery | **Outstanding supported integration proof**, not supplied by ordinary CI or Import cleanup |

CI requires the actual empty-store, already-absent, observed-cleanup and extracted
behavioral markers as well as zero exits. `UNRUN` never satisfies this gate.
The adapted suite compares worker-generated argv to the direct CLI, except the
thumbprint (including its receipt filename) and finishing hold, and exercises
intent denial, deletion/readback faults, residual roots, identity/result faults,
unhealthy session facts and the real QPC cutoff using an expired JobStartCounter.

Native present removal still needs a deliberate supported recovery exercise or a
qualified diagnostic fixture: observed exact unique certificate, truthful owned
preabsence/add-intent facts, healthy supported owned session with documented CUA,
retained actual child exit, logical postabsence and independent cleanup. A healthy
successful hosted Import does not schedule recovery and its cleanup cannot be
relabelled `RemoveOwned`. This route remains open until separately observed.
Failed Windows run 37978106282 remains failed, with cause unknown; these unit and
empty-store boundaries do not explain its add-phase blocking. Exact-source green
CI, hosted disposition, signed prerelease/download hashes, installed normal/VHD
matrix and native consent/removal evidence must be gathered during ticket 569
execution, followed by independent verification, coherent local merge and
delivery, then genuine final human acceptance.


The explicit SSH-only `present-root-recovery` TestFault is a qualified supporting
exercise. Hosted workflow inputs do not expose it, and the supervisor refuses
it under GitHub Actions. Legacy bounded stop faults continue their ordinary
Windows participant tests. Every non-`none` value is excluded from capability
acceptance by the mandatory supervisor verdict binding and watchdog gate.
The exercise worker validates the supervisor's actual job-clock markers even
under SSH; the normal local clock behavior is unchanged.

The exercise intercepts an eligible Import cleanup request before its deletion
intent is authorized, waits the retained importer exit137, then requires the
acknowledged failed prompt result, exact observer identities and an independent
owner health reply. Its accepted worker barrier receives no acknowledgement;
the retained worker Job is stopped and the existing native recovery/RemoveOwned
chain runs. Refused eligibility preserves ordinary acknowledgement and cleanup.
Admission records cleanup385s/recovery165s/margin60s **estimates**, and the
supervisor bounds exercise recovery by J+24 minus the estimated cleanup reserve.
J+21/J+24 and the helper's30s observation bound remain unchanged. An estimate
cannot guarantee cleanup; cutoff or cleanup failure stays failed/unverified.

Native receipts and observer/launcher/recovery results are copied and hash
checked before profile deletion. The killed worker never finalized its outer
cleanup, so the overall supervisor result remains `cleanup-failed`, with
`cleanupStatus=unverified` and nonzero exit. These labels must not be repaired
to obtain supporting credit. `Test-HostedPresentRootRecoverySupport` is a
separate validator requiring the genuine present removal mutation, waited
RemoveOwned result, real CUA removal consent, exact recovery ancestry, timing,
complete recovered cleanup and a distinct independently executed absence check
against the root's exact resource binding, including lease/broker cleanup.
Its synthetic suites do not supply native-present or independent-check credit.

Before citing hosted evidence for570/720/721/729, the root must bind the exact
source/run and require `testFault` exactly `none` in the supervisor identity,
completion and `supervisor-started` ledger record. An SSH supporting run must
be separately bound to the explicit exercise and actual supervisor clock
markers; after full cleanup, a distinct checker records exact resource
identities, original evidence hashes and actual absence. The root supplies
that report and its retained allocation/resource binding to the qualified
validator. A synthetic checker input, empty/already-absent Root path, missing
receipts or an overall successful result cannot satisfy this obligation.
