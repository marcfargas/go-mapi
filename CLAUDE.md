<!-- GSD:project-start source:PROJECT.md -->
## Project

**go-mapi**

go-mapi is a three-tier bridge (C++ MAPI DLL → Go native host → Chrome/Edge extension) that intercepts Windows "Send to Mail recipient" calls and routes them to Gmail as drafts. It's for Windows users who want their legacy desktop apps to compose email through Gmail without installing Outlook.

**Core Value:** A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.

### Constraints

- **Platform**: Windows 10/11 only — MAPI is a Windows API, no cross-platform path exists
- **Licensing**: LGPL-3.0 (Marc's default for FOSS projects) — constrains dependency choices and installer tooling
- **Privacy**: No telemetry, no long-term storage of message content, no network calls outside the Gmail API — baseline for the project
- **Budget**: Solo maintainer, FOSS — code signing must be free or near-free (SignPath.io for OSS, or unsigned with SmartScreen guidance)
- **Distribution**: Extension ships via Chrome Web Store; host installer must be hostable at a stable direct URL reachable from the extension popup
- **Toolchain (dev)**: Windows + Node 18+ + Go 1.21 + MinGW + CMake 3.16+ — end users must not need any of this after v2.0.0
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- Go 1.21 - Native messaging host (`src/native-host/`)
- C++ 17 - MAPI interceptor DLL (`src/interceptor/`)
- TypeScript 5.3.3 - Browser extension UI and logic (`src/extension/`)
- PowerShell - Installation and build scripts (`scripts/install.ps1`, `src/interceptor/build.ps1`)
## Runtime
- Windows 10/11 (MAPI is Windows-only)
- Go runtime for native host
- Chrome/Chromium (and Edge) browser runtime for extension
- npm 9+ (Node 18+) - JavaScript/TypeScript dependencies
- go modules - Go dependencies
## Frameworks
- React 18.2.0 - Extension popup UI (`src/extension/src/popup/`)
- React Bootstrap 2.10.0 - UI components
- Bootstrap 5.3.2 - CSS framework
- Vite 5.0.12 - TypeScript/React bundling for extension
- TypeScript 5.3.3 - Type safety and transpilation
- cmake 3.16+ - C++ build configuration for interceptor
- MinGW (gcc/g++ toolchain) - C++ compilation to DLL
- Vitest 2.1.0 - Unit tests for extension (`src/extension/src/**/__tests__/`)
- Go test - Native host testing (`src/native-host/*_test.go`)
- @testing-library/react 14.2.0 - React component testing
- Playwright 1.58.0 - E2E browser testing (`tests/e2e/`)
- ESLint 9.0.0 with @eslint/js and typescript-eslint - TypeScript/extension linting
- Go vet - Native host linting
## Key Dependencies
- github.com/fsnotify/fsnotify v1.7.0 - File system watching for email JSON files in native host
- golang.org/x/sys v0.4.0 - Windows system calls for native host
- react (18.2.0) - Extension UI framework
- react-dom (18.2.0) - React DOM rendering for popup
- vite (5.0.12) - Extension bundle creation
- typescript (5.3.3) - Type checking for extension code
- @testing-library/jest-dom (6.4.0) - DOM matchers for tests
- jsdom (24.0.0) - DOM simulation for Node.js tests
- vitest (2.1.0) - Test runner and assertion library
- @vitest/coverage-v8 (2.1.0) - Code coverage reporting
- sharp (0.34.5) - Image processing (extension icon handling)
## Configuration
- No explicit .env configuration required for core functionality
- OAuth credentials are baked into extension manifest: `src/extension/public/manifest.json` contains GCP OAuth client ID
- Installation sets Windows Registry keys: `HKLM:\SOFTWARE\Clients\Mail\go-mapi` for MAPI handler registration
- Native messaging manifest: `src/native-host/manifests/` (generated during install for both Chrome and Edge)
- TypeScript config: `src/extension/tsconfig.json` - strict mode, modern target
- Vite config: `src/extension/vite.config.ts` - extension-specific bundling (no code splitting)
- CMake config: `src/interceptor/CMakeLists.txt` - DLL build with MinGW
- ESLint config: `eslint.config.mjs` - flat config format, extends recommended rules
- Playwright config: `tests/e2e/playwright.config.ts` - browser testing configuration
## Platform Requirements
- Windows 10/11
- Node 18+
- Go 1.21+
- MinGW with gcc/g++ toolchain (for C++ compilation)
- CMake 3.16+
- Ninja or Make (for cmake)
- Chrome or Edge for testing
- Admin PowerShell access for installing registry entries
- Windows 10/11
- Chrome or Edge browser (requires extension installation)
- Gmail or Google Workspace account (with OAuth access)
- Admin privileges for initial installation (DLL + registry)
## Build Pipeline
- `npm run build:interceptor` → MinGW + CMake → `src/interceptor/build/bin/go-mapi.dll`
- `npm run build:native-host` → Go build → `src/native-host/build/go-mapi-host.exe`
- `npm run build:extension` → Vite + TypeScript → `src/extension/dist/`
- Build scripts read version from root `package.json` and pass via `-ldflags` to Go and CMake
- Version embedded in binaries at build time (no runtime version detection)
## Compilation Targets
- Output: 32-bit and 64-bit Windows DLL (`go-mapi.dll`)
- Compiled from C++17 sources with MinGW
- Links: kernel32, user32 system libraries
- Release builds: `-O2` optimization, stripped symbols
- Output: `go-mapi-host.exe` (Windows binary)
- Go 1.21 compilation with ldflags for version embedding
- Release builds: `-s -w` strip symbols and debug info (smaller binary)
- Debug builds: keep symbols for debugging
- Output: Chrome extension bundle in `src/extension/dist/`
- Built with Vite (single-pass bundling)
- Manifest v3 compatible
- Service worker (background script) + popup HTML/CSS/JS
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Naming Patterns
- CamelCase with underscores for test variants: `protocol.go`, `protocol_test.go`, `protocol_integration_test.go`
- Descriptive names matching primary type or functionality: `watcher.go`, `gmail.go`
- Test files use `_test.go` suffix for unit tests, `_integration_test.go` for integration tests
- PascalCase for exported functions: `NewEmailWatcher()`, `CreateDraft()`, `SendEmail()`
- camelCase for unexported functions: `processFile()`, `normalizeAddress()`, `handleRemove()`
- Descriptive verb-first names: `Validate()`, `Generate()`, `Normalize()`
- PascalCase for all exported types: `EmailWatcher`, `NativeMessaging`, `MailMessage`, `GmailClient`
- Unexported struct fields in lowercase: `watchDir`, `watcher`, `done`
- camelCase for local variables: `tmpDir`, `watchDir`, `isDir`
- Short names acceptable for loop counters: `i`, `r`, `c`
- Descriptive names for important state: `lastMod`, `pending`, `processed`
- All caps for constants: `MsgTypeEmail`, `maxFileSize`, `maxRetries`
- All caps with underscores: `MsgTypeList`, `MsgTypeProcess`, `MsgTypeDelete`, `MsgTypeCreateDraft`
- Package-level constants describe protocol message types or limits: `gmailAPIBase`, `maxFileSize`
## Code Style
- Standard Go formatting with `gofmt` (enforced by default)
- Line length: No hard limit, but keep readable (convention: ~100 chars practical maximum)
- Spacing: 1 blank line between function definitions, multiple lines for logical grouping within functions
- Uses standard Go toolchain (`go vet`, `go test`)
- No explicit linter configured (relies on Go standard conventions)
- Code follows idiomatic Go patterns from effective Go
- Package-level comments explain purpose: `// NativeMessaging handles Chrome Native Messaging protocol`
- Function-level comments for exported functions document purpose and behavior
- Inline comments explain non-obvious logic or gotchas (e.g., debouncing strategy, retry logic)
- Comments describe "why", not "what" — code should be self-documenting for simple operations
- Always check and propagate errors: `if err != nil { return fmt.Errorf(...) }`
- Wrap errors with context using `%w` verb: `fmt.Errorf("failed to create watcher: %w", err)`
- Error strings are lowercase (Go convention) unless containing code/paths: `"failed to read file"`
- Return early on error, avoid deep nesting
## Import Organization
- No aliases used (imports are explicit)
- Full import paths from standard library or external packages
## Function Design
- Use explicit parameters, no `...interface{}` variadic types (except for `logInfo`/`logError` which use `...interface{}` for format args)
- Receiver parameters use pointer receivers for methods that modify state: `(ew *EmailWatcher)`
- Config parameters grouped into structs where there are 3+ related parameters (not used extensively here)
- Functions return `(result, error)` tuple: `CreateDraft() (string, error)`
- Always check error results; idiomatic Go expects callers to handle errors
- Single return type for simple getters: `GetEmails() map[string]*MailMessage`
- Used for cleanup: `defer ew.Stop()`, `defer ew.mu.RUnlock()`, `defer resp.Body.Close()`
- Placed immediately after acquiring resource to avoid leak
## Concurrency
- `sync.RWMutex` used for protection: `EmailWatcher.mu`
- Lock immediately before accessing shared state: `ew.mu.Lock()` before modifying `ew.emails`
- RUnlock with defer: `defer ew.mu.RUnlock()`
- Write lock for mutations, read lock for reads
- Background work runs in goroutines with explicit lifecycle: `go ew.watchLoop()`
- Signaling done via channel: `ew.done chan struct{}`
- Clean shutdown on `close(ew.done)`
- Used for event signaling and graceful shutdown
- `watcher.Events` channel from fsnotify library for file system events
- Debouncing implemented with map and ticker instead of chan (see `watchLoop`)
## Message Protocol
- Structs use struct tags for JSON field mapping: `json:"type"`, `json:"omitempty"`
- Uppercase exported fields, lowercase JSON keys: `Type` (Go) → `"type"` (JSON)
- Omit empty fields in outgoing messages: `json:"error,omitempty"`, `json:"data,omitempty"`
- Errors sent as messages, not return codes
- Error messages are user-facing descriptions, not stack traces
- Specific error types (e.g., `draft-error`, `error`) distinguish failure categories
## Logging
- Timestamp in RFC3339 format
- Log level prefix ([INFO], [ERROR])
- Sync after every write (ensures visibility for debugging)
- Silent graceful failures if logFile not available
- Info: startup, shutdown, major operations (`"processing email"`, `"native host ready"`)
- Error: failures that need investigation (`"failed to read file"`, `"invalid email"`)
- Omit verbose logs in hot paths (watch loop events logged at info level only on processing)
## Directory and File Location
- `main.go`: Entry point, message loop, version variable, logging setup
- `protocol.go`: Native Messaging protocol types and serialization
- `watcher.go`: Email file system watching and validation
- `gmail.go`: Gmail API client and MIME message building
- Unit tests co-located: `protocol_test.go` tests `protocol.go`
- Integration tests co-located with related module: `watcher_test.go` tests `watcher.go`
- Protocol integration tests load fixtures: `protocol_integration_test.go`
- Fixtures in external directory: `tests/protocol-fixtures/`
## Build and Release
- Version injected at build time via `-ldflags "-X main.Version=..."`
- Default fallback: `var Version = "0.0.0-dev"`
- Version stamped on outgoing messages: `mail.HostVersion = Version`
- `-s -w`: Strip symbols and debug info (release optimization)
## Validation
- Explicit validation function: `validateMailMessage(&mail)`
- Checks required fields: `Version`, `Timestamp`, `BodyFormat`
- Validates enum-like field: `BodyFormat` must be "plain" or "html"
- Validates recipient structure: all recipients must have address
- Early return on first validation error
- Errors moved to `/errors/` directory with `.error` file containing reason
- Strips MAPI prefixes (SMTP:, mailto:) case-insensitively
- Applied to all recipients during processing
- Function `normalizeAddress()` handles single address, `normalizeRecipients()` handles slices
## Special Patterns
- Content-based SHA256 hash combining message body + filename
- Deterministic (same input → same ID)
- Used to detect duplicates and create unique references
- Stored as hex string (64 characters)
- File write debouncing with 500ms grace period
- Pending map tracks files modified recently: `pending[filename] = time.Now()`
- Ticker checks every 100ms, processes if untouched for 500ms
- Handles antivirus file locking via retry loop with 200ms backoff (3 attempts)
- No retention archive (files deleted immediately, not moved to processed/)
- Processed emails deleted with `os.Remove()` not archival
- Explicit comment: `// privacy-first: no retention`
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## Pattern Overview
- Decoupled components via filesystem and native messaging protocol
- Privacy-first: JSON files on disk for debugging; no retention after processing
- Single responsibility: DLL intercepts MAPI, Go bridges to extension, React UI manages Gmail
- Async event handling throughout: watcher notifications, chrome messaging, draft creation
- Minimal dependencies: uses stdlib where possible, relies on Chrome extension APIs
## Layers
- Purpose: Capture MAPI calls from Windows applications, convert to JSON, write to disk
- Location: `src/interceptor/`
- Contains: DLL entry point, MAPI function stubs, message conversion, file I/O
- Depends on: Windows SDK, MinGW C++ runtime
- Used by: Windows "Send to Mail recipient" feature; feeds into Watcher layer
- Purpose: Bridge Windows native context to managed runtime via filesystem events
- Location: `%TEMP%\go-mapi\` (Windows temp directory)
- Contains: Email JSON files (`*.json`), processed folder, errors folder
- Watched by: Go watcher; provides inspectable debugging interface
- Privacy model: Files deleted after being processed or explicitly removed
- Purpose: Watch filesystem, normalize email data, send to extension, handle Gmail API calls
- Location: `src/native-host/`
- Contains: File watcher (fsnotify), native messaging protocol handler, Gmail API client, email validation/normalization
- Depends on: `fsnotify` (file system events), Go stdlib (HTTP, JSON, crypto)
- Used by: Browser extension; sends emails, removes processed files
- Purpose: Binary-safe IPC between Go host and Chrome extension
- Protocol: 4-byte little-endian length prefix + JSON payload
- Location: Protocol types in `src/native-host/protocol.go` and `src/extension/src/types/messages.ts`
- Messages: EMAIL, REMOVED, READY, ERROR, CREATE_DRAFT, DRAFT_CREATED, DRAFT_ERROR, PROCESS, DELETE, LIST, SHUTDOWN
- Reliability: No retries; connection-based (reconnects with 6-second backoff)
- Purpose: Manage native host connection, track email queue, persist state, handle notifications
- Location: `src/extension/src/background/service-worker.ts`
- Contains: Port management, email Map (in-memory), session storage persistence, notification triggers
- Depends on: Chrome extensions API, native messaging
- Used by: Popup UI; listens to filesystem changes via native host
- Purpose: Display email queue, allow user to create drafts or delete emails
- Location: `src/extension/src/popup/`
- Contains: App component (root state), EmailList (queue), EmailDetail (preview + actions), React Bootstrap styling
- Depends on: React, React-Bootstrap, Chrome extension messaging
- Entry point: `src/extension/src/popup/main.tsx`
## Data Flow
- Emails: Stored in `chrome.storage.session.emails` (Map<string, EmailWithId>)
- Recent drafts: Stored in `chrome.storage.session.recentDrafts` (array of 20 most recent)
- On service worker restart: `loadState()` retrieves from session storage
- On email or draft action: `persistEmails()` or `persistDrafts()` writes back
## Key Abstractions
- Purpose: Unified email data structure across all layers
- Examples: `src/native-host/protocol.go` (Go struct), `src/extension/src/types/messages.ts` (TypeScript interface)
- Pattern: Defined in protocol, mirrored in extension for type safety; Go and TypeScript implementations must stay in sync
- Purpose: Encapsulates filesystem monitoring and file-to-ID mapping
- Location: `src/native-host/watcher.go`
- Pattern: Single goroutine watching directory, debouncing writes, maintaining in-memory state
- Methods: `Start()`, `Stop()`, `GetEmails()`, `MarkProcessed()`, `Delete()`
- Purpose: Encapsulates Gmail API operations
- Location: `src/native-host/gmail.go`
- Pattern: Single responsibility — only creates drafts, builds MIME locally, handles auth errors
- Uses `http.Client` directly; no Google SDK dependency
- Purpose: Protocol handler for Chrome native messaging
- Location: `src/native-host/protocol.go`
- Pattern: Read/Write methods handle 4-byte framing, JSON marshaling
- Stateless: Can be tested with mock readers/writers
- Purpose: Central hub for connection, email queue, notifications
- Location: `src/extension/src/background/service-worker.ts`
- Pattern: Global maps for `emails`, `recentDrafts`; connection state stored separately
- Messaging: Broadcasts state changes to popup via `chrome.runtime.sendMessage()`
## Entry Points
- Location: `src/interceptor/main.cpp` (DLL entry point)
- Triggers: App calls `MAPISendMail()` or `MAPISendMailW()` on mapi32.dll
- Responsibilities: Load DLL, initialize logging/file paths, export MAPI functions
- Location: `src/native-host/main.go`
- Triggers: Chrome extension calls `chrome.runtime.connectNative('com.gomapi.host')`
- Responsibilities: Initialize logging, create file watcher, connect stdin/stdout, handle message loop
- Exits: On `MsgTypeShutdown` or stdin EOF
- Location: `src/extension/src/popup/main.tsx`
- Triggers: User clicks extension icon
- Responsibilities: Render App component, fetch initial emails via `chrome.runtime.sendMessage({ action: 'getEmails' })`
- Location: `src/extension/src/background/service-worker.ts` (bottom of file)
- Triggers: Browser loads extension
- Responsibilities: Load persisted state, update badge, connect to native host, set up listeners for alarms/messages/notifications
## Error Handling
- Parse errors: Write to `%TEMP%\go-mapi\errors\{filename}` with `.error` file
- File write errors: Return to calling app (silent; MAPI errors don't block app)
- Logging: Writes to `%TEMP%\go-mapi\native-host.log`
- File read errors: Retry 3 times with 200ms backoff (handles AV software locking)
- JSON parse errors: Move to errors folder, log
- Validation errors: Move to errors folder with reason
- Network errors: Log; send to extension via `SendError()` message
- OAuth token errors: Return `draft-error` with error message, display notification
- Native host disconnection: Retry connection every 6 seconds with alarm
- Auth failure: Show notification "Sign in required", wait for user action
- Draft creation failure: Catch errors, show notification, keep email in queue
- Network/API errors: Send to background console, display in popup as error alert
## Cross-Cutting Concerns
- Approach: File-based for native components (DLL writes to `%TEMP%`, Go writes to `native-host.log`), console for extension
- Pattern: Timestamp + level (INFO/ERROR) + message
- Go logging functions: `logInfo()` and `logError()` in `main.go`
- Extension: `console.log()` and `console.error()` with `[go-mapi]` prefix
- Approach: Validate at boundary layers
- Go: `validateMailMessage()` checks version, timestamp, bodyFormat, recipient addresses
- TS: Type checking via TypeScript interfaces; runtime checks in React components
- DLL: MAPI structure parsing; rejects invalid message structures
- Approach: OAuth 2.0 via Chrome Identity API + token passing to Go
- Chrome handles token refresh; Go passes token as Bearer in Authorization header
- No token storage: Token is ephemeral, obtained per draft creation request
- Gmail API scopes: `https://www.googleapis.com/auth/gmail.compose` and `gmail.send`
- Approach: Delete-on-process, no long-term storage
- DLL: No logging of message content
- Go: Deletes JSON file after email processes (file removal in `MarkProcessed()`)
- Extension: Session storage only (cleared on browser restart)
- No network calls except to Gmail API
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
