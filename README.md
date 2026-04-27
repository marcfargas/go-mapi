# go-mapi

MAPI to Gmail bridge for Windows — a Wails (Go + WebView2) desktop app that routes legacy "Send to Mail recipient" calls to Gmail drafts.

## Status

**Shipping: v3.0 (Wails pivot).** The v2.x Chrome/Edge extension + Go native-host is **retired** and lives only at the `v2.1.0` git tag for archaeology. The browser-store listings are frozen with deprecation messaging pointing here. **Do not run v2.x and v3.0 side-by-side** — uninstall v2.x first, then install v3.0.

| Component | Status | Notes |
|-----------|--------|-------|
| MAPI interception (ANSI + Unicode) | Shipped | C++ DLL unchanged from v1 |
| Wails desktop app (system tray + WebView2) | Shipped | Phase 7 RAM gate PASS — 43.24 MB mean per session (5 concurrent RDS sessions, 2026-04-14) |
| OAuth desktop flow (PKCE loopback + Windows Credential Manager) | Shipped | Phase 8 closed 2026-04-18 |
| Queue viewer + Auto-draft mode | Shipped | Phase 9 |
| Windows toast notifications | Shipped | Phase 9 — XML-path WinRT toasts with `MarkProcessed`/`Delete` dispatch |
| NSIS installer + WebView2 bootstrap + AppUserModelID | Shipped | Phase 10 — single-file `go-mapi-setup.exe`, machine-wide MAPI registration |
| Notify-only autoupdate + release pipeline | Shipped | Phase 11 — stable `releases/latest/download/go-mapi-setup.exe`, in-app "update available" banner |
| Playwright/CDP end-to-end harness | Shipped | Phase 11 — fake Gmail + fake OAuth, 5/5 E2E specs green on CI |

To inspect the retired v2.x source: `git checkout v2.1.0`. No further v2.x fixes will land.

## Architecture

Two components linked by a filesystem drop:

```
┌─────────────────────┐       ┌─────────────────┐       ┌────────────────────┐
│ Any Windows app     │       │ %TEMP%\go-mapi\ │       │ go-mapi (Wails)    │
│ (Word, Excel,       │──────▶│ *.json (DLL     │──────▶│  • Go backend      │
│  Outlook Express,   │       │  writes one     │       │  • Svelte 5 UI     │
│  etc.)              │       │  file per send) │       │  • WebView2 window │
└─────────────────────┘       └─────────────────┘       └────────────────────┘
         │                                                       │
         │ MAPISendMail / MAPISendMailW                          │ Gmail API (PKCE + Credential Manager)
         ▼                                                       ▼
┌─────────────────────┐                                  ┌────────────────────┐
│ go-mapi.dll (C++)   │                                  │ Gmail drafts       │
└─────────────────────┘                                  └────────────────────┘
```

### Components

| Component | Language | Location | Role |
|-----------|----------|----------|------|
| MAPI interceptor | C++17 | `src/interceptor/` | Intercepts `MAPISendMail`/`W`, writes email JSON to `%TEMP%\go-mapi\`. Unchanged from v1. |
| Shared core | Go 1.25 | `internal/mapi/` | Email parsing, validation, watcher (`fsnotify`), Gmail HTTP client + RFC 2822 MIME builder |
| Wails app (backend) | Go 1.25 | `src/app/` | Tray + window lifecycle, auth (OAuth PKCE loopback + Windows Credential Manager via `zalando/go-keyring`), watcher bridge, App-struct bindings |
| Frontend | TypeScript + Svelte 5 | `src/app/frontend/` | WebView2 UI: welcome / sign-in / queue / Auto-draft toggle |

## Why Wails

- **Desktop OAuth without a browser dependency.** WebView2 is the Edge runtime, not Chrome/Edge — the v2.x browser-extension flow could not satisfy enterprise "no Chrome" environments.
- **System tray + native toasts + background Auto-draft mode are first-class.** The browser-extension sandbox blocked all three.
- **WebView2 shares the Edge runtime on Windows**, so RAM cost per instance is measurable and low (43.24 MB mean / 80 MB gate PASS in Phase 7 on 5 concurrent RDS sessions — see `.planning/phases/07-wails-shell-ram-gate/07-VERIFICATION.md`).
- **Go stays the primary language.** The v2.x Go RFC 2822 MIME builder + Gmail client + watcher code survives the pivot and lives in `internal/mapi/`.

## Install

> **Upgrading from go-mapi v2.x?**
> Please uninstall any prior **go-mapi v2.x** **before** installing v3.0 — via **Settings → Apps → Installed apps** (this removes the Chrome/Edge extension + native-host). The v3.0 installer does not migrate v2 artifacts; running both side-by-side is unsupported. **v2.x is retired** and will not receive further updates.

### End-user install

1. Download the latest installer: <https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe>
2. Run it as administrator (required because the installer registers go-mapi as a machine-wide MAPI handler under `HKLM\SOFTWARE\Clients\Mail`).
3. On first launch, sign in with your Google account — the app opens your default browser for OAuth consent.

The installer bundles the Microsoft Edge WebView2 Evergreen Runtime bootstrapper and the C++ MAPI DLL. No manual dependencies are required on end-user machines.

### Updates

go-mapi checks for new releases against the public GitHub Releases feed and surfaces an in-app "update available" banner when a newer version is published. **Updates are manual, not in-process:** clicking the banner opens the GitHub Release page in your default browser, and you download and run the new installer yourself. go-mapi does not replace its own binary.

### Uninstalling on multi-user machines (RDS / shared Windows Server)

When you run the uninstaller on a multi-user host, only the **uninstalling user's** stored Gmail credentials and per-user settings are removed:

- `%APPDATA%\go-mapi\` (settings.json, app.log) — per-user, scrubbed for the uninstalling user only.
- Windows Credential Manager target `go-mapi:oauth-tokens` — per-user (DPAPI-scoped), scrubbed for the uninstalling user only.

Other users on the same machine who signed in to go-mapi retain their own credentials and settings after uninstall. To scrub those, each affected user should manually remove their own `%APPDATA%\go-mapi\` directory and run `cmdkey /delete:go-mapi:oauth-tokens` in their own session.

This limitation is by design: Credential Manager entries and `%APPDATA%` are protected by the Windows per-user data-protection model, and the uninstaller (even when elevated) cannot enumerate and impersonate every profile on the machine.

> For unattended or managed deployments (RDS, MSI/SCCM/Intune fleet roll-outs), see [Enterprise installation](#enterprise-installation) below.

## Enterprise installation

For administrators deploying go-mapi to a fleet (Windows Server / RDS hosts, MSI / SCCM / Intune push, etc.). For single-user installs, the consumer instructions above cover everything.

### Elevation and scope

`go-mapi-setup.exe` is **All Users only**. The MAPI handler is registered under `HKLM\SOFTWARE\Clients\Mail\go-mapi`, which is inherently machine-wide; there is no per-user install path. The installer requires UAC elevation. Run as an administrator (or via a managed-deployment context that elevates) — there is no "Just for me" option.

### Unattended (silent) install

Silent install with all defaults:

```
go-mapi-setup.exe /S /D=C:\Program Files\go-mapi
```

Add `/AUTOUPDATE=1` to register a Windows Scheduled Task that keeps go-mapi updated automatically (see [Automatic updates](#automatic-updates) below):

```
go-mapi-setup.exe /S /AUTOUPDATE=1 /D=C:\Program Files\go-mapi
```

Default is `/AUTOUPDATE=0` (no Scheduled Task; manual update notification only — same as the consumer install).

### Automatic updates

When installed with `/AUTOUPDATE=1` (or with the "Enable automatic updates" checkbox ticked during interactive install), the installer registers a Windows Scheduled Task:

| Property | Value |
|---|---|
| Task name | `go-mapi Auto Update` |
| Path | `\go-mapi Auto Update` (root of Task Scheduler) |
| Run as | `SYSTEM` (no per-user credential, no logon required) |
| Schedule | Daily 03:00 with ±30 minute random delay |
| Also runs | At system startup (5 minute delay) |
| Network | `RunOnlyIfNetworkAvailable=true` (skips offline runs) |
| Catch-up | `StartWhenAvailable=true` (runs after wake/reboot if missed) |
| Concurrency | `MultipleInstancesPolicy=IgnoreNew` (no overlapping runs) |
| Time limit | 12 hours per run (`ExecutionTimeLimit=PT12H`) |

The task fires `go-mapi.exe --update-check-silent`, which:

1. Fetches `SHA256SUMS.txt` from the stable Release URL.
2. Downloads the new binary (or installer) into `%ProgramData%\go-mapi\updates\staging\`.
3. Verifies the SHA-256 digest **before** writing the binary into the install path.
4. Atomically swaps the running `go-mapi.exe` (and the x64 + x86 `go-mapi.dll`) using `MoveFileEx`'s rename-while-running pattern. The interactive go-mapi instance keeps running with its old in-memory file mapping until next launch.
5. Logs to `%ProgramData%\go-mapi\updates\update.log` (admin-readable; no PII, no message content, no hex digests).

The task does **not** restart the running interactive go-mapi.exe. The new binary takes effect on the next launch.

#### Managing the Scheduled Task post-install

Disable temporarily (e.g. during maintenance windows):

```
schtasks /change /tn "go-mapi Auto Update" /disable
```

Re-enable:

```
schtasks /change /tn "go-mapi Auto Update" /enable
```

Run the update check immediately (testing / forced refresh):

```
schtasks /run /tn "go-mapi Auto Update"
```

Inspect last run + status:

```
schtasks /query /tn "go-mapi Auto Update" /v /fo LIST
```

Or open Task Scheduler (`taskschd.msc`) and navigate to `\go-mapi Auto Update`.

The task is removed automatically by the go-mapi uninstaller. To convert an existing notify-only install to silent-update, re-run `go-mapi-setup.exe /AUTOUPDATE=1` over the existing install — the installer is idempotent.

### Integrity verification

Every release publishes `SHA256SUMS.txt` alongside the installer at:

```
https://github.com/marcfargas/go-mapi/releases/latest/download/SHA256SUMS.txt
```

Format follows the `sha256sum` convention (one line per asset, `<lowercase-hex>  <filename>`). The silent updater verifies downloads automatically; for manual verification:

```
$expected = (Invoke-WebRequest 'https://github.com/marcfargas/go-mapi/releases/latest/download/SHA256SUMS.txt').Content
$actual = (Get-FileHash -Algorithm SHA256 .\go-mapi-setup.exe).Hash.ToLower()
Write-Host "Expected: $expected"
Write-Host "Actual:   $actual  go-mapi-setup.exe"
```

SignPath signing (when present on the release) is additive — verify both the SHA-256 digest AND the Authenticode signature for defense-in-depth.

### Multi-user RDS limitation

The uninstaller scrubs the running admin's profile and machine-wide locations (`HKLM\SOFTWARE\Clients\Mail\go-mapi`, `%ProgramFiles%\go-mapi\`, `%ProgramData%\go-mapi\`, `\go-mapi Auto Update`). It does **not** enumerate every user profile on a multi-user / RDS host to scrub `%APPDATA%\go-mapi\` or per-user shortcuts left by older builds. On RDS hosts where many users have run go-mapi, residue may persist in user profiles after uninstall.

This is a known carry-forward limitation from Phase 10 (the v3.0 install milestone). Workaround: an admin can run `Remove-Item -Recurse -Force "$Profile\..\..\..\*\AppData\Roaming\go-mapi"` per RDP session as needed, or wait for the v3.x roadmap entry that adds enumerate-all-profiles uninstall.

### Privacy posture

go-mapi makes network calls only to:

- `https://github.com/marcfargas/go-mapi/releases/latest/download/...` (update check + asset download).
- Google OAuth + Gmail API (when the user signs in / drafts mail).

No telemetry. No content retention. No hash-of-installed-binary reporting. Silent-update logs at `%ProgramData%\go-mapi\updates\update.log` record the version transition and download success/failure only — no message body, no recipient data, no SHA-256 digests of installed binaries.

## Development

### Prerequisites (one-time)

- Windows 10/11
- Go 1.25+
- Node 20+, npm 9+
- MinGW + CMake 3.16+ + Ninja (for the C++ DLL)
- Wails CLI: `go install github.com/wailsapp/wails/v2/cmd/wails@latest`

### Clone + install dependencies

```
git clone https://github.com/marcfargas/go-mapi.git
cd go-mapi
npm install
```

### OAuth credentials (local dev)

Copy `.env.local.example` to `.env.local` at the repo root and fill in your own GCP OAuth desktop client ID + secret. See `.planning/phases/08-oauth-credentials/08-CONTEXT.md` for the GCP setup walkthrough.

### Build the MAPI DLL (once)

```
npm run build:interceptor
```

### Dev loop

```
# Wails hot-reload dev server (Go + Svelte)
scripts/dev-wails.ps1

# Run the test suite locally (matches CI per-PR gate)
npm run test      # Go test (./internal/mapi/... ./src/app/...) + Vitest
npm run check     # go vet + svelte-check
```

### Wails build (release artifact)

```
cd src/app && wails build -platform windows/amd64
# → src/app/build/bin/go-mapi.exe
```

### Race detector (matches per-PR + nightly CI)

```
go test -race ./internal/mapi/... ./src/app/...
```

## Repository layout

```
src/interceptor/             # C++ MAPI DLL (unchanged from v1)
internal/mapi/               # Shared Go core: watcher, protocol, Gmail client + MIME builder
src/app/                     # Wails Go backend (tray, auth, App bindings, watcher bridge)
src/app/frontend/            # Svelte 5 UI
scripts/                     # Dev + measurement scripts (dev-wails, azure-ram-gate, measure-ram, test-drop-email)
tests/sandbox/               # MAPI DLL sandbox tests
tests/protocol-fixtures/     # JSON fixtures consumed by internal/mapi integration tests
.planning/                   # GSD planning artifacts (phase contexts, roadmap, requirements)
```

## License

LGPL-3.0-or-later. See [LICENSE](LICENSE) for the full text.
