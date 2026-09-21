# Component integration gate

This is the compatibility proof for independently released components. It is
not an installer, update, cleanup, or branch-protection check.

On one task-owned CrabBox Windows lease, build or place the independently
selected artifacts, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-component-integration.ps1 `
  -X64Dll src/interceptor/build-x64/bin/go-mapi.dll `
  -X64Harness src/interceptor/build-x64/bin/go-mapi-test-harness.exe `
  -X86Dll src/interceptor/build-x86/bin/go-mapi.dll `
  -X86Harness src/interceptor/build-x86/bin/go-mapi-test-harness.exe `
  -InterceptorVersion <interceptor-version> -AppVersion <app-version> `
  -EvidenceDirectory C:\ProgramData\go-mapi\component-integration
```

The harness explicitly loads each DLL; it does not create product MAPI
registration. For each architecture it retains the native `MAPISendMail`
descriptor, runs the app-owned queue-consumer probe against that exact file,
and writes `component-integration.json`, `component-integration.log`, harness
logs, and app acknowledgements to the evidence directory. Copy those files out
through CrabBox before releasing the lease. Missing evidence is a failure.

Hosted CI validates the script's source contract. It does not publish a
separate non-runtime artifact or represent itself as the Windows proof.
