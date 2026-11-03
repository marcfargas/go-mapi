# Installed attachment regression

This sends two files through Explorer's SendTo menu or the installed x64 MAPI
DLL and current suite app.
The app starts without arguments, authenticates against an isolated Gmail fake,
and creates exactly one draft containing each expected filename and byte sequence.
The queue descriptor must appear and disappear while the app remains alive.

`test-explorer-sendto` starts a fresh Sandbox and owns Suite installation,
generated fixture trust and cleanup inside that guest. It uses the existing
desktop account without creating accounts, loading profiles or provisioning disks.

The lower-level `test-installed-attachment` command requires an already-installed
Suite in a disposable Windows guest and runs as its existing non-elevated desktop
user. Its caller owns installation, WebView2, signer admission when needed and
product/trust cleanup. The lower-level worker does not install products or change
certificate trust.

## Commands

Explorer regression entrypoint:

```powershell
just test-explorer-sendto -Manifest C:\selected\release.json -SuiteMsi C:\selected\go-mapi-suite-3.2.0-beta.2-x64.msi -FakeBinary C:\selected\fake-gmail.exe
```

This installs the selected production-signed Suite only in a fresh Windows
Sandbox, opens Explorer on two owned files under a path containing spaces, and
invokes the classic **Send to > Mail recipient** menu as its ordinary desktop
user. The existing fake checks exactly one draft and exact attachment bytes;
the guest removes the App, product and generated test trust before owned disposal.
The host needs an interactive desktop, `wsb` and PowerShell 7; the guest must
use English Windows menu labels. No other Sandbox may be running. This does not
qualify live Google consent or Explorer Share.

Download the Suite and its `release.json` from the same selected public release.
The manifest binds the MSI, machine App and x64 interceptor hashes; the guest
also requires normal Windows signing trust. The existing
`go-mapi-machine-test-packages-v1` adapter with a complete `suiteC` entry is
accepted too. Build the fake before running, without installing product code:

```powershell
$env:GOWORK = 'off'
go build -C tests/installed-attachment/fake-gmail -o C:\selected\fake-gmail.exe
```

`-EvidenceRoot` selects the retained output parent and `-TimeoutSeconds` bounds
the run (default 900). Inputs are copied into a unique selected directory; the
existing Sandbox runner owns locking, timeout propagation and exact disposal.
Require runner `Status=PASS`, `Cleanup=stopped`, `GuestExitCode=0`,
`installed-smoke-setup.json` and `attachment-result.json` with `passed=true`,
and the smoke directory's `explorer.json`, `worker.json`, `fake-final.json`.
Logs and partial receipts are written directly to the output share so a timeout
retains diagnostics. Inspect failures before retrying; never reuse an unknown guest.

Portable oracle and fake-server checks need no installed product:

```powershell
just test-attachment-tooling
```

After installing the selected suite in the disposable guest, run under its
ordinary desktop user with the staged fixture manifest and built fake:

```powershell
just test-installed-attachment C:\input\machine-test-packages.json C:\input\fake-gmail.exe C:\output
```

The guest launcher supplies `GOMAPI_SANDBOX=1` for the Just disposable-execution
guard. The underlying entrypoint is `Test-Attachment.ps1` with `-Manifest`,
`-FakeBinary` and `-OutputDirectory`. `-Package` defaults to `suiteC` and also
accepts `suiteA` or `suiteB`. Installed EXE and DLL hashes must match that entry.
Build the fake with `GOWORK=off go build` in `fake-gmail` before staging it.

For direct-DLL execution, stage `Test-Attachment.ps1`, `Invoke-Attachment.ps1`,
`Attachment.psm1`, `AttachmentNative.cs`, the fake binary and the fixture
manifest. Explorer mode also needs `ExplorerSendTo.ps1`; its host entrypoint
stages these inputs automatically. A fresh user context is required: the
worker refuses existing go-mapi credentials, queued messages, settings or logs.
It does not replace or remove preexisting user data.

## Results and cleanup

Require `attachment-result.json` with `passed=true`, its smoke directory's worker
and finalized fake receipts, and successful owned-guest disposal. The fake accepts
only its expected Google API tunnel and never forwards requests. After its
`fake-ready.json` appears, the elevated guest setup verifies the SHA256 of the
adjacent `test-ca.pem`, imports that exact CA into LocalMachine Root for this run,
and owns its removal. The normal-user smoke waits up to 30 seconds for those exact
CA bytes; importing a root as a normal user would open a Windows consent dialog.
Synthetic OAuth credentials never contact Gmail.

The launcher assigns the gated worker to an owned job before product execution.
The worker retains the exact app handle and removes its own credentials, settings
and attachment files. App/job exit, fake finalization, product removal and setup's
certificate cleanup all contribute to acceptance; cleanup errors preserve the
original failure.

Mounted-path regression coverage lives in
`internal/mapi/watcher_attachment_path_windows_test.go`: ordinary junction tests
cover attachment acceptance, path resolution and escape rejection. Its opt-in
real-volume test remains available in an elevated disposable guest with
`GO_MAPI_TEST_VHD_MOUNT=1`; it is not an ordinary release requirement.

On 2026-11-04, the maintained Explorer regression passed in Windows 11 Sandbox
build 26100 with the published `3.2.0-beta.2` Suite (source `da252050`). The
existing non-elevated desktop user selected `image.bin` and `report.txt` beneath
a path containing spaces and used **Show more options > Send to > Mail recipient**.
The App created one isolated draft with both exact byte hashes, acknowledged and
emptied the queue, and stopped cleanly. Suite removal, generated CA removal and
exact owned Sandbox disposal also passed. This qualifies that selected package
and OS journey; live Google consent and the broader OS/channel matrix remain
separate.

The earlier direct-DLL smoke passed in Windows Sandbox with the existing desktop account
under a non-elevated token: installed x64 DLL/app hashes, one authenticated draft,
exact attachment bytes, queue publication/deletion and owned cleanup. That run
used the retained `fc5ba082` suite fixture; it does not qualify a new release build.
Oracle/fake tests alone do not establish runtime acceptance. The direct-DLL smoke does
not prove Explorer routing, live Gmail OAuth, x86 interception, reboot or release
signing. Historical installed
profile/VHD and alpha.7 evidence remains historical; their provisioning harness
is retired.
