# Component integration gate

This is the compatibility proof for independently released components. It is
not an installer, update, cleanup, or branch-protection check.

On one approved, task-owned Azure DevTest Labs Windows desktop VM, build or
place the independently selected artifacts, then run:

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
logs, and app acknowledgements to the evidence directory. Read/publish those
files through the RDPilot-controlled interactive desktop session before
tearing the VM down. Missing evidence is a failure.

The `Component Integration Gate` workflow is deliberately `workflow_dispatch`
only. It validates the gate contract and records the selected independent
versions, but its hosted runner artifact is not represented as the authoritative
interactive Windows proof.
