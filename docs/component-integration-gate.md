# Component integration gate

This is the focused compatibility proof for independently released components.
The ordinary Playwright suite exercises the user component against an isolated
queue directory on every development platform. This Windows-only gate proves
that both native system-component architectures emit descriptors accepted by
the real user-component queue consumer.

On one task-owned CrabBox Windows lease, build or place the independently
selected artifacts, then run:

```powershell
just e2e-system-windows `
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
