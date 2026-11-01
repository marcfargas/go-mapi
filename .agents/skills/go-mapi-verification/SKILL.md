---
name: go-mapi-verification
description: Verify go-mapi builds, queue integration, frontend behavior and Windows packages using local Windows tools and disposable Windows Sandbox; maintain affected verification instructions. Use for test evidence and coverage checks, not release publication.
---

# Verify go-mapi

Resolve the checkout explicitly. Read [Windows development](../../../docs/windows-development.md)
for setup and [the component gate](../../../docs/component-integration-gate.md)
when testing component or machine boundaries. Use the current Justfile and script
parameter blocks as executable contracts. Load only the selected journey.

## Select proof and effects

- Frontend: `just build-frontend`, the frontend Vitest and Svelte checks, and
  `just e2e-user`. Playwright drives the built UI through a test Wails bridge
  and an isolated queue; it does not prove the native desktop or Gmail OAuth.
- Core/app: `just test-user` and `just check-user`. Build the frontend first for
  direct Go commands. Windows app tests can require an interactive desktop;
  repeat a session failure in a desktop before diagnosing a product regression.
- Native producer: build x86 and x64 with `src/interceptor/build.ps1 -Tests`,
  then CTest/harness execution. The MAPISendMail harness writes the canonical
  queue, so run it inside the guest. Unit test fixture paths are compiled into
  the binaries; copying an executable alone does not relocate those fixtures.
- Service: compile with `go test -c -o .tmp/service.test.exe ./src/service`, then
  execute the test binary as SYSTEM inside a disposable guest. The test fixture
  creates a service and changes process privilege; compilation alone is host safe.
- Packages: inspect user NSIS/MSIX and machine MSI artifacts with the maintained
  `verify-*` scripts. Install, upgrade, repair, uninstall, certificate creation
  and signing-fixture generation belong in the guest, including the supposedly
  preparatory `build-machine-test-packages.ps1`.
- Installed behavior: use [email integration verification](../../../docs/email-integration-verification.md)
  for Explorer Send-To → queue → UI → Gmail draft. Registry checks, a direct DLL
  caller, and fake-backend UI checks cover narrower contracts.

On Windows, `just check-portable`, `just test-windows` and the race recipe include
service tests. Run these whole recipes in the disposable guest rather than
mistaking their names for a host-safe effect boundary. Do not register MAPI,
install a product, import test trust or create service fixtures on the dev host.

## Prepare, drive and observe

1. Record `git rev-parse HEAD`, `git status --short`, relevant dirty inputs and
   tool versions. Use the qualified Go 1.25 toolchain and Wails 2.12.0. Run the
   documented check-only preparer; missing tools are prerequisites, not passes.
2. Install npm dependencies and Playwright Chromium when setup is authorized.
   Recognize readiness from successful frontend build and the selected harness's
   own readiness checks, not merely an open process or listening port.
3. Run the smallest maintained command that reaches the requested contract.
   Preserve its exit status, stdout, stderr and structured evidence. A warning
   or skipped prerequisite is not an observed pass. After an unexpected failure,
   check session, toolchain, owned process health and clean inputs before retrying.
4. For the guest, use `just sandbox-test` and the [Sandbox README](../../../tests/sandbox/README.md).
   Share selected inputs read-only and unique evidence writable. Never expose
   `.env.local`, host credentials or the whole user profile. A linked worktree's
   `.git` points outside it: use a self-contained disposable clone when Git/archive
   is needed, and record source identity plus local patches. Keep generated
   manifests at their expected guest paths; absolute host paths are not portable.
5. Match observations to artifact SHA-256 hashes and source/build identity.
   App build manifests record HEAD but do not fingerprint every dirty source
   input. Retain the relevant diff or source snapshot alongside results.
6. Check resulting queue descriptors, service/registry state, package contents or
   UI behavior as appropriate. Preserve logs and failures before asserting later
   conditions. Do not infer success from a screenshot, compilation or a helper's
   completion message alone.

Use a unique directory under `test-results/` for reproducible local output; retain
unique failures and accepted evidence under
`$env:LOCALAPPDATA/agent-work/retained/go-mapi/<task>`. Record the concrete path.
Run-created evidence must survive guest teardown. Clean up owned queues, processes,
tasks and the exact guest on success and failure. Never stop another Sandbox or
delete an unverified path. If cleanup ownership is uncertain, report that gap and
preserve evidence rather than killing by process name.

## Native/service selected inputs

Follow the [Sandbox procedure](../../../tests/sandbox/README.md#native-and-optional-service-feedback)
for staging both architectures and optional service tests. Use
`just prepare-native-inputs` and `just sandbox-test`; `just test-native-inputs`
checks host staging contracts separately and does not run product tests.
Inspect the compiled fixture destinations, selected hashes, per-command results,
service fixture removal and exact owned-guest cleanup. Keep unit/direct-DLL proof
separate from installed behavior.

## Local Sandbox constraints

The checked-in `.crabbox.yaml` selects `windows-sandbox`. In an interactive
Windows desktop shell, the initial boundary check is:

```powershell
crabbox doctor --provider windows-sandbox
crabbox run -- powershell -NoProfile -Command "Write-Host ok"
```

Also verify a deliberately nonzero guest exit. Windows Sandbox 0.8.107.0 failed
from T3's service session 0 on this box; use the existing logged-on desktop for
the launch. A temporary scheduled task with that user's interactive token can
bridge an authorized unattended run without credentials; remove the task after
collecting its result. This is a session prerequisite, not permission to create
logons or change identities. Crabbox 0.80.0 may warn that viewer cleanup cannot be
confirmed even after guest shutdown. Check the exact run before continuing.

Sandbox supports same-boot local proof. Reboot/postboot reconciliation,
no-interactive-user, RDS/multi-user, Store deployment, live OAuth and Gmail require
their own prerequisites and observations. A SYSTEM guest command does not prove
absence of an interactive user. Azure compute is unnecessary for supported local
checks; release signing is a separate existing dependency.

## Integrate and maintain

Delivery calls this skill after tool/interface changes and before claiming the
selected behavior. Return commands, candidate identity, observations, evidence,
cleanup and remaining acceptance. Local passes do not prove branch protection,
hosted permissions, mandatory CI enforcement or release readiness. Keep required
remote gates in force; Windows workflows cannot be reproduced by assuming an
ordinary Linux `act` runner has the same environment.

For requested upkeep, compare only affected instructions and callers with current
source and behavior. Correct demonstrated instruction drift or owned harness
gaps and repeat the affected journey. Preserve a product regression's expectation
and failure evidence; use [capture](../go-mapi-capture/SKILL.md) for a distinct
follow-up. Do not lower assertions to obtain a pass. Reconcile impacted user
guidance through [docs](../go-mapi-docs/SKILL.md). Report indexed, exercised,
blocked and untested coverage separately; upkeep starts no schedule or release.
