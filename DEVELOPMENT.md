# go-mapi — Development Guide

Audience: contributors and maintainers. End users do not need any of this — see [README](./README.md) for installation. IT admins deploying at scale should see [ENTERPRISE.md](./ENTERPRISE.md).

## Architecture

Two components linked by a filesystem drop:

```
┌─────────────────────┐       ┌─────────────────┐       ┌────────────────────┐
│ Any Windows app     │       │ %LOCALAPPDATA%\ │       │ go-mapi (Wails)    │
│ (Word, Excel,       │──────▶│ go-mapi\queue\  │──────▶│  • Go backend      │
│  Outlook Express,   │       │ *.json (DLL     │       │  • Svelte 5 UI     │
│  etc.)              │       │  writes one     │       │  • WebView2 window │
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
| MAPI interceptor | C++17 | `src/interceptor/` | Intercepts `MAPISendMail`/`W`, writes email JSON to `%LOCALAPPDATA%\go-mapi\queue\`. Unchanged from v1. |
| Shared core | Go 1.25 | `internal/mapi/` | Email parsing, validation, watcher (`fsnotify`), Gmail HTTP client + RFC 2822 MIME builder |
| Wails app (backend) | Go 1.25 | `src/app/` | Tray + window lifecycle, auth (OAuth PKCE loopback + Windows Credential Manager via `zalando/go-keyring`), watcher bridge, App-struct bindings |
| Frontend | TypeScript + Svelte 5 | `src/app/frontend/` | WebView2 UI: welcome / sign-in / queue / Auto-draft toggle |

## Why Wails

- **Desktop OAuth without a browser dependency.** WebView2 is the Edge runtime, not Chrome/Edge — the v2.x browser-extension flow could not satisfy enterprise "no Chrome" environments.
- **System tray + native toasts + background Auto-draft mode are first-class.** The browser-extension sandbox blocked all three.
- **WebView2 shares the Edge runtime on Windows**, so RAM cost per instance is measurable and low (43.24 MB mean / 80 MB gate PASS in Phase 7 on 5 concurrent RDS sessions — see `.planning/phases/07-wails-shell-ram-gate/07-VERIFICATION.md`).
- **Go stays the primary language.** The v2.x Go RFC 2822 MIME builder + Gmail client + watcher code survives the pivot and lives in `internal/mapi/`.

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

## Prerequisites

- Windows 10/11
- Go 1.25+
- Node 20+, npm 9+
- MinGW + CMake 3.16+ + Ninja (for the C++ DLL)
- Wails CLI: `go install github.com/wailsapp/wails/v2/cmd/wails@latest`

## Clone + install dependencies

```
git clone https://github.com/marcfargas/go-mapi.git
cd go-mapi
npm install
```

## OAuth credentials (local dev)

Copy `.env.local.example` to `.env.local` at the repo root and fill in your own GCP OAuth desktop client ID + secret. See `.planning/phases/08-oauth-credentials/08-CONTEXT.md` for the GCP setup walkthrough.

## Build the MAPI DLL (once)

```
npm run build:interceptor
```

## Dev loop

```
# Wails hot-reload dev server (Go + Svelte)
scripts/dev-wails.ps1

# Run the test suite locally (matches CI per-PR gate)
npm run test      # Go test (./internal/mapi/... ./src/app/...) + Vitest
npm run check     # go vet + svelte-check
```

## Wails build (local production binary)

```
powershell -ExecutionPolicy Bypass -File scripts/build-wails.ps1
# → src/app/build/bin/go-mapi.exe
```

This produces a locally usable production-mode binary and may use the checked-in
`0.0.0-dev` version. A distributable release must use the component's own
non-development version and opt into the guard:

```
# Set src/app/VERSION to the intended app release version first.
powershell -ExecutionPolicy Bypass -File scripts/build-wails.ps1 -Release
```

The interceptor follows the same rule. `-Config Release` controls native
optimisation, while `-Release` opts into the artifact-version guard:

```
# Set src/interceptor/interceptor-version.txt to the intended interceptor release version first.
powershell -ExecutionPolicy Bypass -File src/interceptor/build.ps1 -Arch x64 -Config Release -Release
```

## Race detector

```
go test -race ./internal/mapi/... ./src/app/...
```

Matches the per-PR CI gate and the nightly race-detector workflow.

## IPC protocol

The C++ DLL writes JSON files to `%LOCALAPPDATA%\go-mapi\queue\`; the Go core in `internal/mapi/protocol.go` validates and consumes them. The `MailMessage` struct in that file is the canonical schema.

## Planning artifacts

GSD phase artifacts live in `.planning/`. Start with `STATE.md` and `ROADMAP.md` for the milestone breakdown.
## User app component

The Wails/tray app remains in `src/app` and is independently buildable without
an interceptor, installer, elevation, or machine registration. Its only version
authority is `components.json` → `src/app/VERSION`. From a clean checkout run:

```powershell
npm ci
npm run test:app
npm run check:app
npm run build:app
```

The app opens an empty `%LOCALAPPDATA%\go-mapi\queue` when the interceptor is
absent. Download/elevation handoff and admin installation are separate work.
