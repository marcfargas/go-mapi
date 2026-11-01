# Repository knowledge map

Inspected at baseline `96665564724033447e9e5f0b55d684068b9d0540`. This map
locates evidence; it does not replace the documents or establish their freshness.
Resolve links relative to this resource. Commands in the entrypoint run from the
selected repository root, not from the skill directory.

| Reader/topic | Existing home | Source checks when claims matter |
| --- | --- | --- |
| End-user install and use | [README.md](../../../../README.md) | Current user-app behavior, channels and packaging; do not present intended updates as shipped. |
| Contributors: architecture, prerequisites, dev/build loop | [DEVELOPMENT.md](../../../../DEVELOPMENT.md) | [justfile](../../../../justfile), [package.json](../../../../package.json), [Windows preparation script](../../../../scripts/prepare-windows-build.ps1), invoked build scripts and relevant CI. |
| Enterprise/admin deployment | [ENTERPRISE.md](../../../../ENTERPRISE.md), [MSI README](../../../../src/installer/msi/README.md) | Actual MSI/service scripts and component-specific contracts. |
| User-component ownership/settings/distribution | [app README](../../../../src/app/README.md) | `src/app/`, current app packaging scripts, `components.json`. Frontend README contains template material; inspect actual frontend code/config for project behavior. |
| Inter-component versions/installed state | [compatibility contract](../../../../docs/component-compatibility.md) | [components.json](../../../../components.json), `tests/component-compatibility/`, installed-state readers and producer. Repository tags or equal versions alone do not prove compatibility. |
| Filesystem IPC | [queue-v1](../../../../docs/protocols/queue-v1.md) | [MailMessage/validation](../../../../internal/mapi/protocol.go), `tests/protocol-fixtures/queue-v1/`, native producer. Keep legacy native-messaging envelopes distinct. |
| Component and installed updater proof | [integration gate](../../../../docs/component-integration-gate.md), [email verification](../../../../docs/email-integration-verification.md) | Actual scripts, workflow and candidate-bound evidence. Queue/registry tests do not prove real shell behavior, Gmail delivery, reboot/no-user or multi-user operation. |
| Admin release metadata | [metadata contract](../../../../docs/admin-release-metadata-v1.md) | Current release validation/service readers and their tests. |
| User-channel packaging | [Store](../../../../distribution/store/README.md), [winget](../../../../distribution/winget/README.md) | Channel scripts and actual artifact/provenance checks. |
| Measurements and Sandbox guest checks | [measurements](../../../../docs/measurements/phase-07-ram-gate.md), [Sandbox README](../../../../tests/sandbox/README.md) | Preserve date/environment qualifications. Inspect current harness and recipes before recommending commands. |

## Known qualifications

DEVELOPMENT.md records that `.planning/` was retired in commit `df17ab2` in favor
of Perficio. Historical phase references do not establish a current backlog or
authorize recreating that tree. The Sandbox README documents the selected-input
runner, retained evidence and owned-guest cleanup. Use
[Windows development](../../../../docs/windows-development.md) for the host/guest
split and qualified toolchain. Compare current scripts and CI before using a
particular claim. A discovered stale link does not authorize editing it during retrieval.

The Windows preparation script supports `-Native`, `-Wails`, `-Packages` and
`-Msi` and `-Install`; the install branch can install tooling/change execution policy. Neither listing the command nor a
successful docs check establishes tool readiness or permission to run it.

There is no established documentation publishing provider or dedicated Markdown
checker in the inspected baseline. Repository edits are the supported local
authoring interface; commits, PRs and remote publication retain their original
authorization. No private docs binding is required for local files. App OAuth
configuration is not a knowledge-provider binding, and private values do not
belong in these resources.

The canonical collection is `.agents/skills`, with ordinary-file Claude forwarders
under `.claude/skills`. Capture links directly to docs; build and verification
link here for affected guidance upkeep. Source placement does not establish native
loading or automatic selection. Shared writing and explanation skills are optional
at use time, with local fallbacks in the entrypoint.
