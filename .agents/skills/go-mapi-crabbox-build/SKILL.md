---
name: go-mapi-crabbox-build
description: Prepare and build go-mapi's Windows user app, x86/x64 interceptor and service on the local dev box; package current user NSIS/MSIX and system/suite MSI artifacts. Use Windows Sandbox for machine-changing verification.
---

# Build go-mapi on Windows

Use [local Windows development](../../../docs/windows-development.md) for
Scoop installation, qualified versions and desktop-session constraints. Read the
Justfile and actual script parameter blocks before supplying package arguments.
Use [verification](../go-mapi-verification/SKILL.md) for observable acceptance,
isolation, evidence and cleanup; a successful build establishes compilation only.

When changing the build or setup contract, use
[docs](../go-mapi-docs/SKILL.md) before implementation to put the smallest useful
proposed command/example in the existing guide. After verification, reconcile
that proposal and affected setup/package claims through docs before completion.
Ordinary builds with unchanged contracts need no documentation edit.

## Prepare the current shell

```powershell
$env:GOTOOLCHAIN = 'go1.25.14'
. ./scripts/prepare-windows-build.ps1 -Native -Wails -Packages -Msi
npm ci
```

Go 1.25.x, Wails 2.12.0 and NSIS 3.11 are qualified. Machine MSI projects use
.NET 8 and restore their pinned WiX SDK. The preparer is a bounded check/install
helper; it does not install every prerequisite. Dot-source to retain PATH
changes, or resolve tools in a fresh shell. A Just child cannot change its
parent's PATH. A new host has no implicit Azure lease or credentials requirement.

## Compile independent components

```powershell
just build-frontend
just build-system
just build-service-windows
just build-user
```

The native DLLs are `src/interceptor/build-x64/bin/go-mapi.dll` and
`src/interceptor/build-x86/bin/go-mapi.dll`. The app build retains an executable
and `app-artifacts.json`; use that pair for subsequent verification and packaging.
The version authorities are in `components.json`, including independent app,
interceptor and service version files.

`just build-user` consumes the OAuth environment selected by the existing build
script and Just dotenv support. Alternatively invoke `scripts/build-wails.ps1`
with its `.env.local` path. Keep values private. Explicit fake fixture values
can prove compilation only; a build without real OAuth cannot prove sign-in or
be treated as shippable. Do not ask for credentials in chat.

For release-mode validation, use `just build-user-release`,
`just build-user-machine` and `just build-system-release` with explicit valid
component versions. Use an isolated source copy for temporary version fixtures;
do not silently change canonical versions or dirty source to satisfy guards.
Development and stable release-track rules remain enforced by project scripts.

## Package and inspect

Use the maintained split commands, supplying their required version, artifact and
manifest parameters:

- `just package-user-standalone` builds the per-user NSIS installer.
- `just package-user-msix` builds the per-user MSIX.
- `just package-system` and `just package-suite` build WiX machine MSIs from
  explicit input manifests. Suite consumes a machine-distributed app executable.
- `just verify-user-artifact`, `just verify-user-distribution`,
  `just verify-system-package` and `just verify-suite-package` check their
  corresponding artifacts. Read component package READMEs for exact contracts.

The old `npm run build:interceptor`, combined `src/installer/go-mapi.nsi` and
Inno/native-host installer are obsolete. Do not use them as fallbacks.

Keep ordinary unsigned compilation and package inspection on the host. Run
`build-machine-test-packages.ps1`, which creates machine signing trust, inside
the disposable guest along with service tests and install/update/uninstall.
Crabbox uses `.crabbox.yaml` to select local Windows Sandbox. The guest needs its
own prepared inputs/tools; normal sync excludes ignored build artifacts and does
not provision a guest toolchain. The host worktree's external `.git` pointer is
not a self-contained guest repository.

Return source identity, dirty input qualifications, exact artifacts and hashes,
commands and results. Keep local buildability separate from installer behavior,
release signing, reboot/no-user proof, Gmail authentication and publication.
