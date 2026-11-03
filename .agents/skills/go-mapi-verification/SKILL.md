---
name: go-mapi-verification
description: Verify go-mapi builds, queue integration, frontend behavior and Windows packages using local Windows tools and disposable Windows Sandbox; maintain affected verification instructions. Use for test evidence and coverage checks, not release publication.
---

# Verify go-mapi

Resolve the checkout and select the requested contract. Use the current Justfile
and script parameters, [Windows development](../../../docs/windows-development.md),
and the [component gate](../../../docs/component-integration-gate.md); load only
the relevant journey. These guides supply the procedure even without shared skills.

## Select the boundary

| Contract | Maintained path and limits |
| --- | --- |
| Frontend | `just build-frontend`, frontend Vitest/Svelte checks, `just e2e-user`. Playwright's test bridge/isolated queue does not prove native desktop or OAuth. |
| Core/app | `just test-user`, `just check-user`; frontend build precedes direct Go tests. Repeat interactive-session failures in a desktop before diagnosing a regression. |
| Native/service | Compile on host with `just build-native-tests x64`, `just build-native-tests x86`, `just build-service-tests`; stage via `just prepare-native-inputs`, execute via `just sandbox-test`. Follow the [selected-input procedure](../../../tests/sandbox/README.md#native-and-optional-service-feedback). Runtime fixtures use `GO_MAPI_TEST_FIXTURE_ROOT` and the v3 staging manifest. |
| Packages | Maintained `verify-*` commands inspect NSIS/MSIX/MSI artifacts; installation, repair, upgrade, uninstall and machine signing fixtures execute in the guest. |
| Installed email | `just test-explorer-sendto -Manifest <release.json> -SuiteMsi <suite.msi> -FakeBinary <fake-gmail.exe>` installs the selected Suite in a fresh Sandbox and exercises the real Explorer menu → queue → App → isolated draft fixture as the existing ordinary desktop user. See [installed attachment regression](../../../tests/installed-attachment/README.md) for English-guest prerequisites, receipts and cleanup. Its default direct-DLL mode remains supplemental. [Email verification](../../../docs/email-integration-verification.md) retains live Google consent and other OS/channel acceptance; native tests cover junction handling separately. |

Native harnesses write the canonical queue. Service tests create a service and
change privilege. On Windows, `just check-portable`, `test-windows` and race
recipes include service execution and require disposable execution; compilation
alone is host safe. `just ci` supplies `act -P windows-latest=-self-hosted` for
host checks only: that mapping provides no isolation. Do not install/register
DLLs or services, import trust or build signing fixtures on the dev host.

## Execute and retain

Record HEAD, dirty inputs or a source snapshot, tool versions, exact artifacts
and hashes. App manifests identify HEAD but not every dirty input. Run the
smallest maintained command that reaches the contract and retain exit status,
streams and structured evidence. A missing prerequisite, warning or skipped
journey is not a pass. Check toolchain, session, owned process health and clean
inputs after unexpected failure; keep the original evidence and assertions.

Use `just sandbox-test` and the [Sandbox README](../../../tests/sandbox/README.md)
for selected read-only inputs and unique writable evidence. Never share secrets,
`.env.local` or a whole profile. A worktree's external `.git` needs a self-contained
guest clone/archive if Git is required; preserve source identity/patches and
manifest path bindings. Sandbox launch needs an existing interactive desktop;
SYSTEM command identity does not establish desktop or no-user readiness.
The Windows guide covers authorized session bridging and provider limitations.

Inspect readiness and outputs at the actual boundary: queue, service, registry,
package bytes or UI as applicable. For native/service proof inspect per-command
results, fixture hashes, service-fixture removal and owned-guest disposal.
`test-native-inputs` checks staging only. Export failures before teardown; retain
unique output under `test-results/` and durable evidence under
`$env:LOCALAPPDATA/agent-work/retained/go-mapi/<task>`. Record the concrete path.
Clean owned queues/processes/tasks and the exact guest on success and failure.
Unknown ownership is a reported gap, never grounds to kill by name or delete an
unverified path. Check a deliberately nonzero guest exit when qualifying a provider.

## Report and maintain

Return candidate-bound commands, observations, evidence, cleanup and remaining
acceptance. Separate indexed/exercised/blocked/untested coverage. Same-boot
Sandbox proof does not establish reboot/postboot, no-user, RDS/multi-user, Store,
live OAuth/Gmail or release publication. Local passes do not replace required
remote gates or prove GitHub permissions, branch protection or OIDC.

For requested upkeep, compare only affected guidance/callers with current source
and behavior; correct demonstrated drift and repeat affected journeys where
authorized. Preserve product regression expectations and failures. Use
[capture](../go-mapi-capture/SKILL.md) for distinct follow-ups and
[docs](../go-mapi-docs/SKILL.md) for impacted guidance. Upkeep starts no schedule,
release or broader audit.
