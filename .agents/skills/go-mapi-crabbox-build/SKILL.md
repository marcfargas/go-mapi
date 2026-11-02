---
name: go-mapi-crabbox-build
description: Prepare and build go-mapi's Windows user app, x86/x64 interceptor and service on the local dev box; package current user NSIS/MSIX and system/suite MSI artifacts. Use Windows Sandbox for machine-changing verification.
---

# Build go-mapi on Windows

Follow [Windows development](../../../docs/windows-development.md) for tool setup,
qualified versions, commands and desktop-session constraints. Read the current
Justfile and component parameter blocks for arguments. Use
[verification](../go-mapi-verification/SKILL.md) for acceptance: compilation alone
does not prove installer or installed behavior. For contract changes, use
[docs](../go-mapi-docs/SKILL.md) to propose the smallest guide/example before
implementation and reconcile it after verification; unchanged builds need no edit.

```powershell
$env:GOTOOLCHAIN = 'go1.25.14'
just doctor-windows
just install
just build-frontend
just build-system
just build-service-windows
just build-user
```

Developer tool installation and qualified versions are in the guide; GitHub runner
provisioning belongs to its setup action. Local act packaging checks installed tools
without installing them. Open a fresh shell
after installation: Just cannot change its parent's PATH. No Azure lease is
implicit. Native outputs are `src/interceptor/build-{x64,x86}/bin/go-mapi.dll`;
keep app EXE and `app-artifacts.json` together for packaging and verification.
`components.json` identifies independent component version authorities.

App builds consume private OAuth environment/dotenv inputs or the build script's
explicit `.env.local` path. Never expose values or request credentials in chat.
Fake fixture values prove compilation only, not sign-in or a shippable artifact.
Release validation uses `build-user-release`, `build-user-machine` and
`build-system-release` with valid component versions. Keep temporary version
fixtures in an isolated source copy; preserve canonical version/track guards.

Use `just package-user` for CI's unsigned user-package validation; real user
releases use the app release workflow and shared packaging action. Build machine
packages with `just package-system` or `just package-suite` and explicit manifests. Verify with
`verify-user-artifact`, `verify-user-distribution`, `verify-system-package` and
`verify-suite-package`; component READMEs define their contracts. Suite needs a
machine-distributed app. The combined NSIS installer, Inno/native-host flow and
`npm run build:interceptor` are obsolete, not fallback paths.

Keep unsigned compilation and inspection on the host. Machine fixture building
(`just build-machine-test-packages`), service tests and install/update/uninstall
belong in a disposable guest because they create machine trust or service state.
`.crabbox.yaml` selects local Windows Sandbox; ignored host artifacts/tools are not
automatically provisioned, and a linked worktree's external `.git` is not a
self-contained guest repository. Follow the guide for selected inputs and source
identity. Return source/dirty qualifications, artifacts/hashes, commands and
results; keep signing, reboot/no-user, live Gmail and publication acceptance distinct.
