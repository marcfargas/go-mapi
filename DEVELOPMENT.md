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
| Development commands | `Justfile`, `.github/actions/`, component build/test files | Shared development commands, packaging and hosted orchestration |
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
`just build-user-machine`. Public signing and publication are coordinated by
`.github/workflows/release.yml` and its reusable App/machine builders;
local fixture passes do not establish release readiness.

For a production-signed release, use one `v<version>` tag and the
`release.yml` workflow. App and Suite ship at that version every time. System
ships only when its interceptor, service, registration, privileged installer,
compatibility or relevant build inputs change. Otherwise Suite embeds the exact
signed payload from a selected published System release and the release notes
link its original download. System skips numbers in the shared sequence.
Suite remains a complete offline MSI; its package version can advance while its
contained System version stays unchanged. System and Suite retain distinct MSI
families and update ownership.

1. Set App's source version. For a new System, set service and interceptor to
   the same release version. Merge reviewed source and require successful full
   push CI for that exact commit, then create `v<version>` there.
2. Configure the protected `artifact-signing` environment with Azure account
   `lachispa`, profile `lachispa`, endpoint `https://weu.codesigning.azure.net/`
   and the existing signing OIDC identity. Supply real OAuth credentials and
   `ADMIN_RELEASE_METADATA_URL` as a **bare HTTPS origin**, such as
   `https://go-mapi.app`, without a metadata path, query or fragment. The old
   legacy-admin full metadata URL is no longer accepted.
3. Dispatch from the exact tag to build a new System:

   ```powershell
   gh workflow run release.yml --ref v<version>
   ```

   To reuse System, select its published tag and independently verify the SHA256
   of its `release.json` before dispatch:

   ```powershell
   gh workflow run release.yml --ref v<version> -f system_tag=v<system-version> -f system_manifest_sha256=<sha256>
   ```

   Reuse requires the same release track and unchanged machine source, installer,
   compatibility and build inputs. A track transition requires a new System.
   The workflow verifies the old MSI, provenance, default Windows trust and
   extracted PE hashes; it never rebuilds or resigns reused files. The first
   unified release needs a new System because these machine contracts changed.
4. The workflow builds distinct standalone and machine App binaries, signs new
   System files once, packages Suite and optional System, then stages **one
   complete draft**. The public bundle contains the per-user EXE,
   MSIX, Suite MSI, optional new System MSI, and one `release.json` recording
   package hashes, source and contained System identity. Detailed build/signing
   receipts and update targets remain CI artifacts; WinGet generates its own
   submission from the accepted installer. The first consolidated-format release
   builds a new System; later reuse reads only that format.
   Download the draft and compare its packages with `release.json` and the CI
   signing evidence. In clean disposable Windows, verify default Authenticode trust,
   installation/removal and the [ordinary-user attachment smoke](tests/installed-attachment/README.md).
   For reused System, verify an App-only Suite upgrade preserves those exact
   machine payload hashes. Import no product-signing certificate. A timeout
   leaves acceptance incomplete.
5. Immediately before promotion, recheck tag commit, release/asset IDs and
   freshly downloaded hashes against the accepted bundle. Promote those same
   bytes using `gh release edit v<version> --draft=false`, selecting
   `--prerelease --latest=false` for development. Download public assets
   anonymously and compare every byte again. Stable `release.published` handling
   submits the accepted standalone installer and MSIX to winget/Store without
   rebuilding; external certification/catalog availability remains separate.
   An existing draft must be resumed from its recorded assets, never rebuilt
   or replaced by rerunning release staging.

The production-signed unified `v3.2.0-beta.2` release qualified the compact
metadata layout, hosted signing and disposable-Windows package/attachment
acceptance. Published assets remain immutable. Reused-System acceptance uses an
unpublished draft from the same release workflow; it does not require another
public release.

Proposed reused-System acceptance commands (runtime qualification pending):
after exact-source push CI passes, tag the App-only candidate and dispatch
`release.yml` with the published System tag and independently downloaded
`release.json` SHA-256. Download the complete draft to `candidate`, the original
published bundle to `prior`, and the run's `release-app` / `release-machine`
artifacts to `receipts/app` / `receipts/machine`. Save the actual draft notes as
`notes.txt`. Check the packages against the actual assembler and CI receipts:

```powershell
uv run --script tests/release/Verify-ReusedRelease.py `
  --prior-release prior/release.json --bundle candidate --receipts receipts `
  --notes notes.txt --source <candidate-commit> --run-id <release-run> `
  --run-attempt 1 --output reused-release.json
pwsh -NoProfile -File tests/release/Prepare-ReusedSuite.ps1 `
  -PriorBundleDirectory prior -BundleDirectory candidate `
  -PriorMachineReceiptsDirectory prior-receipts/machine `
  -MachineReceiptsDirectory receipts/machine -OutputDirectory selected-suite
just sandbox-test -InputDirectory <absolute-selected-suite> `
  -ScriptPath Test-ReusedSuite.ps1 -RunAs System -TimeoutSeconds 900
```

The preparer selects only the two Suite MSIs and their existing compact release
and signing receipts. The guest uses default Windows signature trust, disables
its network adapters before installation, installs the old Suite and upgrades
it to the candidate. It checks MSI registration and Suite ownership, new App
bytes/version, unchanged service and both interceptor payloads, service health
and final removal. The existing Sandbox runner exports evidence and disposes
only its owned guest. Receipt checks alone do not prove Windows trust or an
installed upgrade; contract tests use inert files. This journey does not qualify
the standalone App's live metadata or UAC consent path.

Standalone App's installation/repair action now selects System with administrator
consent through the existing verified-download and UAC helper. It refuses Suite,
ambiguous machine identity and untrusted installation state. Missing-System
bootstrap validates the real App and target interceptor compatibility; existing
System repair uses the MSI package version and preserves installer policy.
Suite maintenance remains administrator controlled.

Live update metadata is a separate deployment. Its configured origin must serve
`/machine/system/targets.json` and `/machine/suite/targets.json`; requests include
`X-Go-Mapi-Release-Track` (`stable` or `development`), and ordinary updates include
`X-Go-Mapi-Installed-Version`. Bootstrap has no invented installed version.
Targets expire within 31 days. Refreshing authorization dates for the same
immutable payload is supported; changing its bytes or compatibility at an
accepted package sequence is refused. CI retains generated target documents;
publishing `release.json` does not deploy that metadata service. Live discovery, UAC installation
and metadata refresh still need deployment and guest acceptance.

MSIX uses the shared Windows package sequence plus a zero fourth component, so
successive alphas have distinct numeric identities. Older alpha.11 packages used
`3.2.0.0`; the alpha.11 to beta.1 upgrade to `3.2.201.0` passed disposable-Windows
acceptance. Development MSIX publisher identity comes from the actual signing
certificate. Production signing does not establish SmartScreen reputation.

The old `.planning/` tree was intentionally retired in commit `df17ab2` in favor
of Perficio. Historical phase/ticket references may help recover decisions but
are not a current local backlog. Do not recreate the retired planning tree from
stale links.
