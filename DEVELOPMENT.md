# go-mapi — Development Guide

For contributors and maintainers. See [README](README.md) for installation and
[ENTERPRISE.md](ENTERPRISE.md) for deployment and machine-update settings.

## Architecture and ownership

Simple MAPI callers load the machine-wide x86/x64 interceptor, which writes
queue-v1 messages and owned attachments under `%LOCALAPPDATA%\go-mapi\queue`.
The signed-in user's Wails/tray app consumes that queue and creates Gmail drafts.
The resident LocalSystem service maintains the installed system or suite MSI;
it does not process mail or own users' Gmail credentials.

| Area | Source | Responsibility |
| --- | --- | --- |
| Interceptor | `src/interceptor/` | Native Simple MAPI producer and installed dispatch probes |
| Shared core | `internal/mapi/` | Protocol validation, watcher, Gmail client and MIME |
| User app | `src/app/`, `src/app/frontend/` | OAuth, tray/window, queue consumer, settings and update guidance |
| Machine updater | `src/service/`, `src/service/cmd/go-mapi-service/` | Health, authenticated targets, protected staging and MSI update recovery |
| Machine installers | `src/installer/msi/` | Mutually exclusive system/suite products, service and machine registration |
| Host tooling | `scripts/`, `scripts/tests/` | Builds, packages, verification orchestration and tooling contracts |
| Test journeys | `tests/e2e/`, `tests/sandbox/` | Browser UI checks and disposable Windows guest programs |

Wails supplies the native shell and WebView2 UI; Go owns application behavior.
The [historical RAM measurement](docs/measurements/phase-07-ram-gate.md) records
43.24 MB mean in four clean scheduled-session samples on Windows Server 2022.
It is historical evidence, not current v4 RDS qualification.

`components.json` defines independent component versions and compatibility
ranges. Read [queue-v1](docs/protocols/queue-v1.md) and
[component compatibility](docs/component-compatibility.md) before changing either
boundary. System MSI includes interceptor/service; suite also includes the
machine-distributed app. Per-user app packages remain independent.

## Set up and build

Use [Local Windows development](docs/windows-development.md) for the Scoop
prerequisites, qualified Go 1.25.x / Node 20 / Wails 2.12.0 toolchain, package
tools and Sandbox desktop requirements. Commands below run from the repo root.

```powershell
git clone https://github.com/marcfargas/go-mapi.git
cd go-mapi
just install
```

Copy `.env.local.example` to `.env.local` and supply your own GCP desktop OAuth
client configuration. Keep it private. `just build-user` uses that configuration;
fixture credentials establish compilation only and cannot qualify sign-in.

```powershell
just build-system                 # x86 and x64 interceptor
just build-service-windows        # versioned service executable
just build-user                   # src/app/build/bin/go-mapi.exe
just dev-user                     # development build with devtools, then launch
```

Serialize frontend/Wails builds within a checkout because Go embeds the generated
`frontend/dist`. For frontend hot reload, run `wails dev` from `src/app` with the
required OAuth environment; `just dev-user` builds and launches, without a watch loop.

## Choose checks by their effects

```powershell
just test-user                    # builds frontend; Go core/app plus Vitest
just check-user                   # Go vet plus Svelte checks
just e2e-user                     # browser UI with a test Wails bridge/isolated queue
just test-windows-tooling         # host script contracts; no product install
```

Browser tests do not prove installed MAPI dispatch, real WebView2 behavior or
Google OAuth. Build the frontend before direct Go tests. Core/app race feedback:

```powershell
just build-frontend
go test -race ./internal/mapi/... ./src/app/...
```

CI's Windows race job also includes the service package. On Windows,
`just check-portable`, `just test-windows`, native DLL harness execution and
service tests have machine or canonical-queue effects. Run those in disposable
Windows; do not treat their names as proof they are host safe.

For x86/x64 test compilation, fixture staging and SYSTEM guest execution, use the
[Sandbox procedure](tests/sandbox/README.md). Its host staging contracts require
built artifacts and are separately selectable with `just test-native-inputs`.
For actual producer/consumer integration, installed MSI lifecycle and unattended
system/suite updater scenarios, follow the
[component integration gate](docs/component-integration-gate.md). That document
maps CI jobs, fixture signing, evidence and the separate reboot/no-user phases.
For ordinary-user Explorer Send-To through Gmail, use
[email integration verification](docs/email-integration-verification.md).

## Package and release

Use [Windows development](docs/windows-development.md) for package commands,
[MSI contracts](src/installer/msi/README.md) for machine inputs and migrations,
and the [Store](distribution/store/README.md) / [winget](distribution/winget/README.md)
references for external channel requirements. Package inspection is distinct from
installation or update acceptance. Signing-fixture generation imports machine
trust and belongs in the disposable guest.

Development versions use odd-major SemVer with an `alpha`, `beta` or `nightly`
identifier. Stable versions use an even major without a prerelease identifier;
`4.0.0` is a stable release identity. Select each component and package version
explicitly before promotion. Stable `3.0.x` versions are a legacy exception.
The app, interceptor and service have separate version files; a package release
also has its own identity. A repository tag alone does not establish compatibility.

`just build-user-release` and `just build-system-release` enforce release-version
guards; native `-Config Release` alone only selects optimization. Use the selected
component versions and exact artifact/build manifests. Machine app builds use
`just build-user-machine`. Public signing and publication remain controlled by
`.github/workflows/app-release.yml` and `.github/workflows/admin-release.yml`;
local fixture passes do not establish release readiness.

Machine publication currently allowlists selected experimental 3.2 releases and
a TEST ONLY signing profile. Publishing a stable 4.0 machine package requires a
reviewed publication/signing policy change and final-byte qualification; changing
a version file or tag alone will fail those guards. This restriction does not
remove the independent app workflow's stable release path.

The old `.planning/` tree was intentionally retired in commit `df17ab2` in favor
of Perficio. Historical phase/ticket references may help recover decisions but
are not a current local backlog. Do not recreate the retired planning tree from
stale links.
