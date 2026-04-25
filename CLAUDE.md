<!-- GSD:project-start source:PROJECT.md -->
## Project

**go-mapi**

go-mapi is a two-component Wails (Go + WebView2) desktop app that intercepts Windows "Send to Mail recipient" calls and routes them to Gmail as drafts. A C++ MAPI DLL writes email JSON to `%LOCALAPPDATA%\go-mapi\queue\`; the Wails app (Go backend + Svelte 5 frontend) watches that directory, signs the user in via Google OAuth desktop flow (PKCE loopback), and creates Gmail drafts on request. It's for Windows users who want their legacy desktop apps to compose email through Gmail without installing Outlook.

**Core Value:** A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.

### Constraints

- **Platform**: Windows 10/11 only — MAPI is a Windows API, no cross-platform path exists
- **Licensing**: LGPL-3.0 (Marc's default for FOSS projects) — constrains dependency choices and installer tooling
- **Privacy**: No telemetry, no long-term storage of message content, no network calls outside the Gmail API — baseline for the project
- **Budget**: Solo maintainer, FOSS — code signing must be free or near-free (SignPath.io for OSS, or unsigned with SmartScreen guidance)
- **Distribution**: v3.0 ships a single-file NSIS installer (Phase 10) reachable from a stable GitHub Releases URL; the WebView2 Evergreen runtime is bootstrapped by the installer
- **Toolchain (dev)**: Windows + Node 20+ + Go 1.25 + MinGW + CMake 3.16+ + Wails CLI — end users do not need any of this
- **Two-component stack**: C++17 MAPI DLL (unchanged from v1) + Go/Svelte Wails app. The v2.x browser-based UI and Go native messaging host are retired and live only at the `v2.1.x` git tag.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- Go 1.25 - Wails backend + shared core (`src/app/`, `internal/mapi/`)
- TypeScript 5.x + Svelte 5 - Wails frontend (`src/app/frontend/`)
- C++ 17 - MAPI interceptor DLL (`src/interceptor/`) — unchanged from v1
- PowerShell - Build + dev scripts (`scripts/dev-wails.ps1`, `scripts/measure-ram.ps1`, `src/interceptor/build.ps1`)
## Runtime
- Windows 10/11 (MAPI is Windows-only)
- WebView2 Evergreen runtime (required by Wails; bootstrapped by the v3.0 installer in Phase 10)
- Go runtime (1.25+) for the Wails app
- Node 20+ + npm 9+ for frontend tooling and workspace scripts
- go modules + `go.work` workspace (`./internal/mapi`, `./src/app`)
## Frameworks
- Wails v2.12.0 - Desktop app framework (Go ↔ WebView2)
- Svelte 5 - Frontend UI framework (runes mode: `$state`, `$props`, `$derived`)
- Vite 6 - Frontend build pipeline
- Vitest 2.x - Frontend unit + component tests (`src/app/frontend/src/**/*.test.ts`)
- @testing-library/svelte 5.x - Svelte 5 component testing helpers
- jsdom - DOM environment for Vitest
- svelte-check - TypeScript regression gate for `.svelte` + `.ts` files (blocking in CI)
- Go test (stdlib) - Go unit + integration tests; `-race` runs as per-PR CI gate on `./internal/mapi/... ./src/app/...`
- fyne.io/systray v1.12.0 - System tray integration (RunWithExternalLoop pattern)
- cmake 3.16+ + MinGW (gcc/g++) - C++ DLL build
## Key Dependencies
- github.com/wailsapp/wails/v2 v2.12.0 - Wails framework (Go side)
- fyne.io/systray v1.12.0 - System tray icon, menu, click handling
- github.com/fsnotify/fsnotify v1.9.0 - `%LOCALAPPDATA%\go-mapi\queue\` watcher (transitive via `internal/mapi`)
- github.com/zalando/go-keyring v0.2.8 - Windows Credential Manager for OAuth token storage
- golang.org/x/oauth2 v0.36.0 - PKCE loopback flow helpers
- github.com/pkg/browser - System-browser opener for OAuth consent
- golang.org/x/sys v0.30.0 - Windows system calls (single-instance mutex, session-end)
- svelte ^5.0.0 + @sveltejs/vite-plugin-svelte ^5.0.0 - Frontend framework + Vite plugin
- @testing-library/svelte ^5.2.0 + jsdom ^24.0.0 - Frontend test scaffolding
## Configuration
- `src/app/wails.json` - Wails project config (name, version, frontend path, output binary)
- OAuth credentials are injected at build time via `-ldflags "-X main.oauthClientID=... -X main.oauthClientSecret=..."`; at `wails dev` time read from `GOMAPI_OAUTH_CLIENT_ID` / `GOMAPI_OAUTH_CLIENT_SECRET` env vars (`.env.local` at repo root, gitignored)
- Keyring entry: service=`go-mapi`, user=`oauth-tokens`, stored as JSON via `zalando/go-keyring`
- Frontend: `src/app/frontend/vite.config.ts`, `src/app/frontend/tsconfig.json`, `src/app/frontend/vitest.config.ts` (jsdom + `src/test/setup.ts`)
- CMake config: `src/interceptor/CMakeLists.txt` - DLL build with MinGW
- Installation registers Windows Registry keys: `HKLM:\SOFTWARE\Clients\Mail\go-mapi` for MAPI handler registration (Phase 10 owns the v3.0 install path)
## Platform Requirements
**Developer:**
- Windows 10/11
- Node 20+, npm 9+
- Go 1.25+
- MinGW with gcc/g++ toolchain (for the C++ DLL)
- CMake 3.16+ + Ninja
- Wails CLI: `go install github.com/wailsapp/wails/v2/cmd/wails@latest`

**End user:**
- Windows 10/11
- WebView2 Evergreen runtime (bootstrapped by the v3.0 installer per Phase 10 INST-02)
- Gmail or Google Workspace account
## Build Pipeline
- `npm run build:interceptor` → MinGW + CMake → `src/interceptor/build-x64/bin/go-mapi.dll` and `src/interceptor/build-x86/bin/go-mapi.dll`
- `cd src/app && wails build -platform windows/amd64` → `src/app/build/bin/go-mapi.exe` (embeds frontend via `go:embed`)
- `go test ./internal/mapi/... ./src/app/...` (add `-race` to match per-PR CI gate)
- `npm run -w @marcfargas/go-mapi-app-frontend test:run` (Vitest)
- `npm run -w @marcfargas/go-mapi-app-frontend check` (svelte-check)
- Version embedded via `-ldflags "-X main.Version=..."` (handled by Wails release tooling in Phase 11)
## Compilation Targets
**MAPI DLL (`go-mapi.dll`):**
- 32-bit and 64-bit Windows DLL
- Compiled from C++17 sources with MinGW
- Links: kernel32, user32 system libraries
- Release builds: `-O2` optimization, stripped symbols

**Wails app (`go-mapi.exe`):**
- Windows amd64 binary
- Go 1.25 compilation; frontend assets embedded via `go:embed`
- Release builds: `-s -w` strip symbols and debug info (smaller binary)
- Debug builds: keep symbols for debugging
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Naming Patterns
- Test files use `_test.go` suffix for unit tests, `_integration_test.go` for integration tests, `*_windows_test.go` (`//go:build windows`) for platform-specific tests
- Descriptive file names matching primary type or functionality: `auth.go`, `watcher_bridge.go`, `gmail.go`, `tray.go`, `paths.go`, `singleinstance.go`, `sessionend.go`
- PascalCase for exported functions: `NewAuthManager()`, `CreateDraft()`, `GetQueue()`
- camelCase for unexported functions: `processFile()`, `normalizeAddress()`, `refreshIfNeededLocked()`
- Descriptive verb-first names: `Validate()`, `Generate()`, `Normalize()`, `SignIn()`, `SignOut()`
- PascalCase for all exported types: `AuthManager`, `EmailWatcher`, `MailMessage`, `GmailClient`, `KeyringStore`
- Unexported struct fields in lowercase: `watchDir`, `tokens`, `email`, `done`
- camelCase for local variables: `tmpDir`, `lastMod`, `srv`
- Short names acceptable for loop counters: `i`, `r`, `c`
- All caps with underscores for protocol/keyring constants: `keyringService`, `keyringUser`, `MsgTypeEmail`
- Package-level vars for ldflags injection: `oauthClientID`, `oauthClientSecret`, `Version` (lowercase package-private; written by `-ldflags -X`)
## Code Style
- Standard Go formatting with `gofmt` (enforced by default)
- Line length: No hard limit; convention ~100 chars
- Spacing: 1 blank line between function definitions, multiple lines for logical grouping
- Standard Go toolchain (`go vet`, `go test`)
- No explicit Go linter configured beyond `go vet`; idiomatic Go patterns from effective Go
- Frontend (TypeScript/Svelte): strict mode via `tsconfig.json`; `svelte-check` is the blocking lint gate (no ESLint)
- Package-level comments explain purpose: `// AuthManager owns OAuth state + token refresh.`
- Function-level comments for exported functions document purpose and behavior
- Inline comments explain non-obvious logic or gotchas (e.g., debouncing strategy, keyring.ErrNotFound semantics, build-tag splits)
- Comments describe "why", not "what" — code should be self-documenting for simple operations
- Always check and propagate errors: `if err != nil { return fmt.Errorf(...) }`
- Wrap errors with context using `%w` verb: `fmt.Errorf("failed to create watcher: %w", err)`
- Error strings are lowercase (Go convention) unless containing code/paths
- Return early on error, avoid deep nesting
## Import Organization
- No aliases used (imports are explicit)
- Full import paths from standard library or external packages
- `internal/mapi` imported into `src/app` via the `replace` directive in `src/app/go.mod` (workspace)
## Function Design
- Use explicit parameters; no `...interface{}` variadic types except for log helpers (`logInfo`, `logError`)
- Pointer receivers for methods that modify state: `(am *AuthManager)`, `(b *watcherBridge)`
- Functions return `(result, error)` tuple: `CreateDraft() (string, error)`
- Always check error results; idiomatic Go expects callers to handle errors
- Single return type for simple getters: `IsAuthenticated() bool`
- Defer used for cleanup: `defer srv.Close()`, `defer am.mu.Unlock()`, `defer resp.Body.Close()`
- Placed immediately after acquiring resource to avoid leak
## Concurrency
- `sync.RWMutex` for shared-state protection: `AuthManager.mu`, `watcherBridge.mu`
- Lock immediately before accessing shared state; unlock with defer
- Write lock for mutations, read lock for reads
- Background work runs in goroutines with explicit lifecycle: `go b.dispatchLoop()`
- Signaling done via `chan struct{}` + `sync.Once` for idempotent close
- Clean shutdown on `close(b.done)`
- `watcher.Events` channel from fsnotify for file system events
- Debouncing implemented with map and ticker (see `EmailWatcher.watchLoop`)
## Wails Bindings
- The Go `App` struct in `src/app/app.go` exposes methods that Wails binds into the frontend (`wailsjs/go/main/App`)
- Bindings are introspected by `wailsbindings.exe` at build time — fatal startup guards (e.g., `checkOAuthCredentials`) MUST live in non-`bindings`-tagged files (build-tag split) so introspection does not trigger `os.Exit`
- Events flow back to the frontend via `wruntime.EventsEmit(ctx, "queue-changed", payload)`; the frontend subscribes via `EventsOn` from `wailsjs/runtime/runtime`
## Svelte 5 (frontend)
- Runes mode throughout: components use `$props()` destructuring, `$state` for local state, `$derived` for computed values
- Component file names: PascalCase (`SignInScreen.svelte`, `PreAuthModal.svelte`, `ReAuthBanner.svelte`, `SignedInHeader.svelte`)
- Pure logic modules in `src/app/frontend/src/lib/*.ts` (`auth.ts`, `queue.ts`); components in `src/app/frontend/src/lib/components/`
- Component tests render via `@testing-library/svelte` `render()`; mock wailsjs bindings with `vi.mock('../../wailsjs/go/main/App', ...)`
- No browser-extension APIs anywhere in the frontend (no `chrome.*`, no `browser.*`)
## Logging
- Timestamp in RFC3339 format
- Log level prefix ([INFO], [ERROR])
- Sync after every write (ensures visibility for debugging)
- Silent graceful failures if logFile not available
- Info: startup, shutdown, major operations (`"oauth: signed in as %s"`, `"app: ready"`)
- Error: failures that need investigation (`"failed to read file"`, `"refresh: invalid_grant; tokens cleared"`)
- Omit verbose logs in hot paths (watch loop events logged at info level only on processing)
- **Never log secrets:** no token values, no email body, no subject text, no attachment content. Counts and error types are safe.
## Directory and File Location
**`src/app/` (Wails Go backend):**
- `main.go` — Wails app entry; calls `NewApp()`, `wails.Run(...)`
- `app.go` — App struct + bindings exposed to frontend (`GetQueue`, `SignIn`, `SignOut`, `GetAuthStatus`, ...)
- `auth.go` — `AuthManager`, OAuth PKCE loopback, token refresh, keyring storage
- `auth_credentials.go` — `oauthClientID` / `oauthClientSecret` package vars (ldflags-injected)
- `credentials_check.go` — fatal startup guard, build-tag split for `wailsbindings`
- `tray.go` — fyne.io/systray integration
- `singleinstance.go` — Windows kernel mutex
- `sessionend.go` — `WM_QUERYENDSESSION` handler (clean exit on logoff/shutdown)
- `watcher_bridge.go` — bridges `internal/mapi.EmailWatcher` to Wails event emission
- `paths.go` — `%APPDATA%\go-mapi\` + `%LOCALAPPDATA%\go-mapi\queue\` resolution + env-var precedence
- `logging.go` — `%APPDATA%\go-mapi\app.log` writer
- Tests co-located: `auth_test.go`, `watcher_bridge_test.go`, `singleinstance_test.go`, `sessionend_test.go`, `app_test.go`, `paths_test.go`, `auth_keyring_windows_test.go` (Windows-only)

**`internal/mapi/` (shared Go core, imported by `src/app/`):**
- `protocol.go` — `MailMessage` struct + JSON validation + recipient normalization
- `watcher.go` — `EmailWatcher` (fsnotify + debounce + retry-on-AV-lock)
- `gmail.go` — `GmailClient`, RFC 2822 MIME builder, draft POST to Gmail API
- `testutil/` — fixture path helpers
- Tests: `protocol_test.go`, `protocol_integration_test.go`, `watcher_test.go`, `gmail_test.go`, `mime_golden_test.go`
- Fixtures: `tests/protocol-fixtures/` (loaded via `testutil.FixturePath`)

**`src/app/frontend/` (Svelte 5 UI):**
- `src/main.ts` — Svelte app entry
- `src/App.svelte` — root component
- `src/lib/auth.ts`, `src/lib/queue.ts` — pure logic modules (call wailsjs bindings)
- `src/lib/components/SignInScreen.svelte`, `PreAuthModal.svelte`, `ReAuthBanner.svelte`, `SignedInHeader.svelte`
- `src/test/setup.ts` — Vitest global setup
- `vitest.config.ts` — jsdom + Svelte plugin
- `wailsjs/` — auto-generated Go bindings + runtime helpers (DO NOT EDIT)

**`src/interceptor/` (C++ MAPI DLL — unchanged from v1):**
- `main.cpp` — DLL entry point; exports `MAPISendMail`/`MAPISendMailW`
- `CMakeLists.txt` — MinGW build config
- `build.ps1` — convenience wrapper around CMake + MinGW
## Build and Release
- Version injected at build time via `-ldflags "-X main.Version=..."`
- Default fallback: `var Version = "0.0.0-dev"`
- `-s -w`: Strip symbols and debug info (release optimization)
- OAuth credentials injected via `-ldflags "-X main.oauthClientID=... -X main.oauthClientSecret=..."` (Phase 8); env-var fallback for `wails dev`
- Phase 11 (REL-02) owns the v3.0 release pipeline + SignPath signing
## Validation
- Explicit validation function: `validateMailMessage(&mail)` in `internal/mapi/protocol.go`
- Checks required fields: `Version`, `Timestamp`, `BodyFormat`
- Validates enum-like field: `BodyFormat` must be "plain" or "html"
- Validates recipient structure: all recipients must have address
- Early return on first validation error
- Errors moved to `%LOCALAPPDATA%\go-mapi\queue\errors\` directory with `.error` file containing reason
- Strips MAPI prefixes (SMTP:, mailto:) case-insensitively (`normalizeAddress`, `normalizeRecipients`)
## Special Patterns
- Content-based SHA256 hash combining message body + filename → deterministic queue ID (hex string, 64 chars)
- File write debouncing with 500ms grace period (`pending[filename] = time.Now()` + 100ms ticker)
- Antivirus file-lock retry: 3 attempts, 200ms backoff
- No retention archive: `os.Remove()` after draft created (explicit comment: `// privacy-first: no retention`)
- Build-tag split for fatal startup guards: `credentials_check.go` (no `//go:build bindings`) vs a sibling stub under `//go:build bindings` so `wailsbindings.exe` can introspect types without `os.Exit`
- KeyringStore interface seam: production wraps `zalando/go-keyring`; tests use an in-memory fake (cross-platform); a Windows-only `*_windows_test.go` exercises the real Credential Manager on `windows-latest` CI
- HTTP endpoint override vars in `auth.go` (`tokenEndpointOverride`, `revokeEndpointOverride`) — production reads from constants; tests inject `httptest.Server` URLs
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## Pattern Overview
- Two components linked by filesystem IPC: C++ MAPI DLL (writes JSON) + Go/Svelte Wails app (watches + processes)
- Privacy-first: no retention — emails are deleted from `%LOCALAPPDATA%\go-mapi\queue\` after draft creation or dismissal
- Single Wails process owns: tray icon, main window, watcher goroutine, AuthManager, GmailClient
- Async event handling throughout: watcher notifications, Wails events, OAuth callbacks
- Minimal dependencies; stdlib preferred; no chrome APIs anywhere
## Layers
**MAPI Interceptor (C++ DLL, `src/interceptor/`)**
- Purpose: Capture MAPI calls from Windows applications, convert to JSON, write to `%LOCALAPPDATA%\go-mapi\queue\`
- Contains: DLL entry point, MAPI function stubs, message conversion, file I/O
- Depends on: Windows SDK, MinGW C++ runtime
- Used by: Windows "Send to Mail recipient" feature; feeds the Wails app's watcher
- Unchanged from v1.

**Filesystem IPC (`%LOCALAPPDATA%\go-mapi\queue\`)**
- Purpose: Bridge Windows native context to the Wails app via filesystem events
- Contains: Email JSON files (`*.json`), `errors/` subdirectory for invalid messages
- Watched by: `internal/mapi.EmailWatcher` (fsnotify + debounce)
- Privacy model: Files deleted after draft creation or explicit dismissal

**Shared core (`internal/mapi/`)**
- Purpose: Email parsing, validation, normalization; file watcher; Gmail HTTP client
- Contains: `protocol.go`, `watcher.go`, `gmail.go`, `testutil/`
- Imported by: `src/app/` via `go.work` workspace + `replace` directive
- Stateless: no goroutines own permanent state; all state belongs to the caller (`src/app/`)

**Wails App (`src/app/`)**
- Purpose: Tray + window lifecycle, OAuth + keyring, watcher bridge, App-struct bindings
- Contains: `main.go`, `app.go`, `auth.go`, `tray.go`, `singleinstance.go`, `sessionend.go`, `watcher_bridge.go`, `paths.go`, `logging.go`, `credentials_check.go`
- Depends on: `internal/mapi`, `github.com/wailsapp/wails/v2`, `fyne.io/systray`, `golang.org/x/oauth2`, `github.com/zalando/go-keyring`, `github.com/pkg/browser`
- Single process owns: tray icon, hidden main window, watcher goroutine, AuthManager, GmailClient
- Build-tag split: fatal startup guards extracted to non-`bindings`-tagged files so `wailsbindings.exe` introspection does not trigger `os.Exit`

**Frontend (`src/app/frontend/`)**
- Purpose: Svelte 5 UI rendered in WebView2
- Contains: `App.svelte`, `lib/auth.ts`, `lib/queue.ts`, `lib/components/{SignInScreen,PreAuthModal,ReAuthBanner,SignedInHeader}.svelte`
- Depends on: Svelte 5, Vite 6, auto-generated wailsjs bindings
- Today: welcome / sign-in screen, pre-auth explainer modal, re-auth banner, signed-in header
- Phase 9 lands the queue view + Manual / Auto-draft toggle
## Data Flow
**Email arrival → UI:**
1. Windows app calls `MAPISendMail`/`W` → `go-mapi.dll` writes JSON to `%LOCALAPPDATA%\go-mapi\queue\`
2. `internal/mapi.EmailWatcher` (fsnotify) sees the new file, debounces 500ms, validates JSON
3. Watcher invokes the `WatcherCallback` registered by `src/app/watcher_bridge.go`
4. The bridge calls `wruntime.EventsEmit(ctx, "queue-changed", payload)`
5. Frontend `EventsOn("queue-changed", ...)` triggers a re-fetch via `GetQueue` Wails binding
6. Go returns the current queue snapshot from `internal/mapi.EmailWatcher.GetEmails()`
7. Svelte UI re-renders the list

**User action → Gmail:**
1. User clicks "Create draft" in Svelte UI → `wailsjs/go/main/App.CreateDraft(id)`
2. App struct invokes `AuthManager.MakeAuthenticatedGmailCall(...)` (refresh-if-near-expiry, retry-once on 401)
3. `internal/mapi.GmailClient` (stateless) builds RFC 2822 MIME, POSTs to `/gmail/v1/users/me/drafts`
4. On success, `internal/mapi.EmailWatcher.MarkProcessed(id)` deletes the JSON file
5. App emits `queue-changed` to refresh the UI; tray badge count updates

**OAuth lifecycle:**
- `SignIn()` → start loopback listener on a random port → open system browser to Google consent → receive code on loopback → exchange via `oauth2.Config.Exchange()` → fetch userinfo → save to keyring → emit `auth-changed`
- Token refresh transparent to user; `invalid_grant` clears tokens, sets `am.invalidGrant = true`, emits `auth-changed{authenticated:false, invalidGrant:true}` → frontend shows re-auth banner
## Key Abstractions
**`MailMessage` (in `internal/mapi/protocol.go`)**
- Unified email data structure across DLL JSON, watcher state, Gmail MIME builder
- JSON struct tags drive both serialization (Wails bindings) and DLL output parsing

**`EmailWatcher` (in `internal/mapi/watcher.go`)**
- Encapsulates filesystem monitoring + file-to-ID mapping
- Pattern: single goroutine watching directory, debouncing writes, maintaining in-memory state
- Methods: `Start()`, `Stop()`, `GetEmails()`, `MarkProcessed()`, `Delete()`
- Constructor takes a `WatcherCallback` for change notifications (plumbed by `src/app/watcher_bridge.go`)

**`GmailClient` (in `internal/mapi/gmail.go`)**
- Stateless: receives access token per call (no internal token state)
- Single responsibility: builds MIME locally + POSTs to Gmail API
- Uses `http.Client` directly; no Google SDK dependency
- Endpoint base injectable for `httptest.Server` in tests

**`AuthManager` (in `src/app/auth.go`)**
- Owns OAuth state + refresh logic + keyring read/write + invalid_grant handling
- KeyringStore interface seam: real impl wraps `zalando/go-keyring`; in-memory fake for cross-platform unit tests; Windows-only integration test for real Credential Manager
- HTTP endpoint override vars (`tokenEndpointOverride`, `revokeEndpointOverride`) for `httptest`-based tests

**`watcherBridge` (in `src/app/watcher_bridge.go`)**
- Bridges `internal/mapi.EmailWatcher` events to Wails event emission
- Pattern: goroutine + channel + `sync.Once` for idempotent close

**App struct (in `src/app/app.go`)**
- Wails-bound: every method becomes a JS callable (`wailsjs/go/main/App.*`)
- Holds: `*AuthManager`, `*EmailWatcher`, visibility state, `intentionalQuit atomic.Bool`
## Entry Points
**MAPI DLL** — `src/interceptor/main.cpp`
- Triggers: app calls `MAPISendMail()` / `MAPISendMailW()` via `mapi32.dll`
- Responsibilities: load DLL, initialize logging/file paths, export MAPI functions

**Wails app** — `src/app/main.go`
- Triggers: user launches `go-mapi.exe` (or installer registers it as autostart in Phase 10)
- Responsibilities: `checkOAuthCredentials()` fatal-guard → `singleinstance.Acquire()` → `NewApp()` → `wails.Run(...)`
- Exits: on `intentionalQuit`, `WM_QUERYENDSESSION`, or normal Wails shutdown

**Frontend** — `src/app/frontend/src/main.ts`
- Triggers: WebView2 loads the embedded HTML
- Responsibilities: render `<App />`, subscribe to `auth-changed` and `queue-changed` events
## Error Handling
**MAPI DLL:**
- Parse errors: write to `%LOCALAPPDATA%\go-mapi\queue\errors\{filename}.error` with reason
- File write errors: silent — MAPI errors must not block the calling app

**`internal/mapi`:**
- File read errors: 3 retries with 200ms backoff (handles AV software locking)
- JSON parse errors: move file to `errors/`, log
- Validation errors: move file to `errors/` with reason
- Gmail HTTP errors: returned as Go errors with `%w` wrapping; classified by `AuthManager` (401 → refresh-and-retry-once; 4xx/5xx → bubble up)

**`src/app`:**
- AuthManager errors surfaced to UI via `auth-changed` event payload (`{authenticated:false, invalidGrant:true, error:"..."}`)
- Watcher errors logged + emitted via `queue-error` event
- Tray icon flips state on credential-store-unavailable / signed-out

**Frontend:**
- `lib/queue.ts` `fetchQueue` returns `[]` when binding returns null (WR-03 regression locked in tests)
- `subscribeQueue(onChange, onError)` separates happy + error paths
- Auth status drives screen routing: unauthenticated → SignInScreen; invalidGrant → ReAuthBanner; authenticated → SignedInHeader + queue
## Cross-Cutting Concerns
**Logging**
- Approach: file-based for the Wails app (`%APPDATA%\go-mapi\app.log`); DLL logs to `%LOCALAPPDATA%\go-mapi\queue\interceptor.log`
- Pattern: timestamp (RFC3339) + level (INFO/ERROR) + message
- Helpers: `logInfo()` / `logError()` in `src/app/logging.go`

**Input validation**
- Go: `validateMailMessage()` checks version, timestamp, bodyFormat, recipient addresses
- TS: TypeScript strict mode + svelte-check at build/CI time
- DLL: MAPI structure parsing rejects invalid message structures

**Authentication**
- Approach: OAuth 2.0 desktop flow (PKCE loopback) — `golang.org/x/oauth2` + `github.com/pkg/browser`
- Token storage: Windows Credential Manager via `zalando/go-keyring` (service=`go-mapi`, user=`oauth-tokens`)
- Token refresh: AuthManager refreshes when `Expiry < now + skew`; `invalid_grant` clears tokens + emits re-auth event
- Gmail API scopes: `https://www.googleapis.com/auth/gmail.compose` and `gmail.send`

**Privacy**
- DLL: no logging of message content
- Go: `os.Remove()` after draft created (no archive)
- Frontend: no localStorage of email content; only `hasSeenPreAuthExplainer` flag persists
- No network calls except Gmail API (and Google OAuth endpoints during sign-in/refresh)

**Concurrency safety**
- AuthManager mutex protects `tokens`, `email`, `name`, `invalidGrant`
- watcherBridge `sync.Once` makes `Close()` idempotent
- App `atomic.Bool` for `intentionalQuit` and `visible` flags
- Per-PR CI runs `go test -race ./internal/mapi/... ./src/app/...` (D-07)
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, or `.github/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
