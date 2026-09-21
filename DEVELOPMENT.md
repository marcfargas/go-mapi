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

The product boundaries are the **user component** and **system component**.
Narrower names in the table describe their implementation modules; persisted
compatibility fields retain their existing `app` and `interceptor` identifiers.

| Component | Language | Location | Role |
|-----------|----------|----------|------|
| System component (MAPI interceptor) | C++17 | `src/interceptor/`, `src/installer/msi/` | Machine-wide x86/x64 MAPI registration; writes email JSON to `%LOCALAPPDATA%\go-mapi\queue\`. |
| Shared core | Go 1.25 | `internal/mapi/` | Email parsing, validation, watcher (`fsnotify`), Gmail HTTP client + RFC 2822 MIME builder |
| User component (Wails backend) | Go 1.25 | `src/app/` | Per-user tray + window lifecycle, auth (OAuth PKCE loopback + Windows Credential Manager via `zalando/go-keyring`), watcher bridge, App-struct bindings |
| User component frontend | TypeScript + Svelte 5 | `src/app/frontend/` | WebView2 UI: welcome / sign-in / queue / Auto-draft toggle |

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
scripts/                     # Build, validation, diagnostics, and local development entrypoints
tests/sandbox/               # MAPI DLL sandbox tests
tests/protocol-fixtures/     # JSON fixtures consumed by internal/mapi integration tests
.planning/                   # GSD planning artifacts (phase contexts, roadmap, requirements)
```

## Prerequisites

- Windows 10/11
- Go 1.25.x (the qualified Wails toolchain)
- Node 20+, npm 9+
- MinGW + CMake 3.16+ + Ninja (for the C++ DLL)
- Wails CLI: `go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0`

## Clone + install dependencies

```
git clone https://github.com/marcfargas/go-mapi.git
cd go-mapi
just install
```

## OAuth credentials (local dev)

Copy `.env.local.example` to `.env.local` at the repo root and fill in your own GCP OAuth desktop client ID + secret.

## Build the system component (Windows only)

```
just build-system
```

## Dev loop

```
# Windows shell with local `.env.local` credentials
just dev-user

# Run the test suite locally (matches CI per-PR gate)
just test-user    # Go user-component tests + Vitest
just check-user   # go vet + svelte-check
just e2e-user     # Playwright + isolated queue; runs on Linux/macOS/Windows
```

## Wails build (local production binary)

```
just build-user
# → src/app/build/bin/go-mapi.exe
```

This produces a locally usable production-mode binary and may use the checked-in
`0.0.0-dev` version. A distributable release must use the component's own
non-development version and opt into the guard:

```
# Set src/app/VERSION to the intended app release version first.
just build-user-release
```

The interceptor follows the same rule. `-Config Release` controls native
optimisation, while `-Release` opts into the artifact-version guard:

```
# Set src/interceptor/interceptor-version.txt to the intended interceptor release version first.
just build-system-release
```

## End-to-end tests

```
just e2e-user
```

The ordinary Playwright suite is platform-neutral. It drives the built Svelte
UI through the Wails binding contract and an isolated queue directory, while
Go tests exercise the real queue consumer. Windows is reserved for the native
x86/x64 producer, canonical queue-path, updater, packaging, and installer
boundaries; run those through `just e2e-system-windows` and the package recipes.

## Race detector

Build `src/app/frontend/dist` first because the Go binary embeds it:

```
just build-frontend
go test -race ./internal/mapi/... ./src/app/...
```

This matches the nightly race-detector workflow.

## IPC protocol

The C++ DLL writes JSON files to `%LOCALAPPDATA%\go-mapi\queue\`; the Go core in `internal/mapi/protocol.go` validates and consumes them. The `MailMessage` struct in that file is the canonical schema.

## User component

The Wails/tray application remains in `src/app` and is independently buildable
without the system component, elevation, or machine registration. Its only version
authority is `components.json` → `src/app/VERSION`. From a clean checkout run:

```
just install
just test-user
just check-user
just build-user
```

The user component opens an empty `%LOCALAPPDATA%\go-mapi\queue` when the system
component is absent. Download/elevation handoff and system installation remain
separate operations.

## Release lines

Development builds use odd-major canonical SemVer with an explicit `alpha`,
`beta`, or `nightly` prerelease identifier. Stable builds use the corresponding
even major without a prerelease identifier; for example, `3.1.0-beta.2`
promotes to `4.1.0`. Existing stable `3.0.x` versions are a legacy exception.
