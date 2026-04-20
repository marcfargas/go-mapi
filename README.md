# go-mapi

MAPI to Gmail bridge for Windows — a Wails (Go + WebView2) desktop app that routes legacy "Send to Mail recipient" calls to Gmail drafts.

## Status

| Component | Status | Notes |
|-----------|--------|-------|
| MAPI interception (ANSI + Unicode) | Stable | C++ DLL unchanged from v1 |
| Wails desktop app (system tray + WebView2) | In progress | Phase 7 PASS — 43.24 MB mean per session (2026-04-14, 5 concurrent RDS sessions) |
| OAuth desktop flow (PKCE loopback + Windows Credential Manager) | In progress | Phase 8 shipped 2026-04-18 |
| Queue viewer + Auto-draft mode | Planned | Phase 9 |
| Windows toast notifications | Planned | Phase 9 |
| NSIS installer + WebView2 bootstrap + AppUserModelID | Planned | Phase 10 |
| Notify-only autoupdate + release pipeline | Planned | Phase 11 |

This is **v3.0** (Wails pivot). The v2.x browser-based UI + Go IPC host is archived at the v2.1.x git tag; it is no longer maintained and will be unpublished from the relevant browser add-on stores when v3.0 ships. To inspect the v2.x source: `git checkout v2.1.0`.

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
> Please uninstall any prior **go-mapi v2.x** **before** installing v3.0 — via **Settings → Apps → Installed apps** (this removes the Chrome/Edge extension + native-host). The v3.0 installer does not migrate v2 artifacts; running both side-by-side is unsupported.

The v3.0 installer ships in Phase 10. Until then, dev install only — see [Development](#development) below.

### Uninstalling on multi-user machines (RDS / shared Windows Server)

When you run the uninstaller on a multi-user host, only the **uninstalling user's** stored Gmail credentials and per-user settings are removed:

- `%APPDATA%\go-mapi\` (settings.json, app.log) — per-user, scrubbed for the uninstalling user only.
- Windows Credential Manager target `go-mapi:oauth-tokens` — per-user (DPAPI-scoped), scrubbed for the uninstalling user only.

Other users on the same machine who signed in to go-mapi retain their own credentials and settings after uninstall. To scrub those, each affected user should manually remove their own `%APPDATA%\go-mapi\` directory and run `cmdkey /delete:go-mapi:oauth-tokens` in their own session.

This limitation is by design: Credential Manager entries and `%APPDATA%` are protected by the Windows per-user data-protection model, and the uninstaller (even when elevated) cannot enumerate and impersonate every profile on the machine.

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

LGPL-3.0-or-later. See [COPYING](COPYING) for the full GPL-3.0 text and [LICENSE](LICENSE) for the LGPL-3.0 additional permissions.
