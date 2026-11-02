# Installed attachment smoke

This sends two files through the installed x64 MAPI DLL and current suite app.
The app starts without arguments, authenticates against an isolated Gmail fake,
and creates exactly one draft containing each expected filename and byte sequence.
The queue descriptor must appear and disappear while the app remains alive.

Run inside a disposable Windows guest under its existing non-elevated desktop
user. The owning MSI setup installs the selected suite, admits its signer and
provides WebView2 before this smoke; that setup also owns product and signer
cleanup. This test does not create accounts, load or migrate profiles, provision
virtual disks, install products or modify trust.

## Commands

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

Stage the five PowerShell/C# implementation and contract files in this directory,
the fake binary and the fixture manifest. A fresh user context is required: the
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

The simplified smoke passed in Windows Sandbox with the existing desktop account
under a non-elevated token: installed x64 DLL/app hashes, one authenticated draft,
exact attachment bytes, queue publication/deletion and owned cleanup. That run
used the retained `fc5ba082` suite fixture; it does not qualify a new release build.
Oracle/fake tests alone do not establish this runtime acceptance. The smoke does
not prove Explorer routing, live Gmail OAuth, x86 interception, reboot or release
signing. Historical installed
profile/VHD and alpha.7 evidence remains historical; their provisioning harness
is retired.
