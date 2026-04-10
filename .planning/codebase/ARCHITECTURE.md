# Architecture

**Analysis Date:** 2026-04-10

## Pattern Overview

**Overall:** Three-tier event-driven bridge architecture with file-system IPC between Windows native layer (C++/Go) and browser extension (React/TypeScript).

**Key Characteristics:**
- Decoupled components via filesystem and native messaging protocol
- Privacy-first: JSON files on disk for debugging; no retention after processing
- Single responsibility: DLL intercepts MAPI, Go bridges to extension, React UI manages Gmail
- Async event handling throughout: watcher notifications, chrome messaging, draft creation
- Minimal dependencies: uses stdlib where possible, relies on Chrome extension APIs

## Layers

**Interceptor Layer (C++):**
- Purpose: Capture MAPI calls from Windows applications, convert to JSON, write to disk
- Location: `src/interceptor/`
- Contains: DLL entry point, MAPI function stubs, message conversion, file I/O
- Depends on: Windows SDK, MinGW C++ runtime
- Used by: Windows "Send to Mail recipient" feature; feeds into Watcher layer

**File System IPC (JSON):**
- Purpose: Bridge Windows native context to managed runtime via filesystem events
- Location: `%TEMP%\go-mapi\` (Windows temp directory)
- Contains: Email JSON files (`*.json`), processed folder, errors folder
- Watched by: Go watcher; provides inspectable debugging interface
- Privacy model: Files deleted after being processed or explicitly removed

**Native Host Layer (Go):**
- Purpose: Watch filesystem, normalize email data, send to extension, handle Gmail API calls
- Location: `src/native-host/`
- Contains: File watcher (fsnotify), native messaging protocol handler, Gmail API client, email validation/normalization
- Depends on: `fsnotify` (file system events), Go stdlib (HTTP, JSON, crypto)
- Used by: Browser extension; sends emails, removes processed files

**Native Messaging Protocol:**
- Purpose: Binary-safe IPC between Go host and Chrome extension
- Protocol: 4-byte little-endian length prefix + JSON payload
- Location: Protocol types in `src/native-host/protocol.go` and `src/extension/src/types/messages.ts`
- Messages: EMAIL, REMOVED, READY, ERROR, CREATE_DRAFT, DRAFT_CREATED, DRAFT_ERROR, PROCESS, DELETE, LIST, SHUTDOWN
- Reliability: No retries; connection-based (reconnects with 6-second backoff)

**Service Worker Layer (TypeScript):**
- Purpose: Manage native host connection, track email queue, persist state, handle notifications
- Location: `src/extension/src/background/service-worker.ts`
- Contains: Port management, email Map (in-memory), session storage persistence, notification triggers
- Depends on: Chrome extensions API, native messaging
- Used by: Popup UI; listens to filesystem changes via native host

**UI Layer (React):**
- Purpose: Display email queue, allow user to create drafts or delete emails
- Location: `src/extension/src/popup/`
- Contains: App component (root state), EmailList (queue), EmailDetail (preview + actions), React Bootstrap styling
- Depends on: React, React-Bootstrap, Chrome extension messaging
- Entry point: `src/extension/src/popup/main.tsx`

## Data Flow

**MAPI Capture → DLL → Filesystem:**

1. Windows app calls `MAPISendMail()` or `MAPISendMailW()`
2. DLL intercepts call (installed via registry: `HKEY_LOCAL_MACHINE\SOFTWARE\Clients\Mail\go-mapi`)
3. `MAPISendMailA()` or `MAPISendMailW()` in `src/interceptor/main.cpp` delegates to `MapiImpl::MAPISendMailA/W()`
4. `MapiImpl::ConvertAnsiMessage()` or `ConvertWideMessage()` converts MAPI structures to JSON
5. Normalizes recipient addresses (strips SMTP:, mailto: prefixes)
6. Writes JSON to `%TEMP%\go-mapi\{uuid}.json`
7. Returns `SUCCESS_SUCCESS` to Windows app

**Filesystem → Native Host → Extension:**

1. File watcher detects `.json` file creation in `%TEMP%\go-mapi\`
2. Debounces writes (waits 500ms for file to settle)
3. Reads and validates JSON; moves invalid files to `errors/` folder
4. Generates ID via SHA256(file_content + filename)
5. Stores in in-memory `emails` map
6. Sends `NativeMessaging.SendEmail(id, mail)` to extension via native protocol
7. Service worker receives, stores in `chrome.storage.session`, updates badge
8. Broadcasts `QUEUE_UPDATE` to popup UI

**Gmail Draft Creation:**

1. Email arrives in queue
2. Service worker calls `chrome.identity.getAuthToken()` to get OAuth token
3. On success, sends `NativeCreateDraftMessage` to Go host (type=create-draft, token, email with attachments)
4. Go's `handleCreateDraft()` receives token and email
5. Calls `GmailClient.CreateDraft()` which:
   - Builds full RFC 2822 MIME message locally (including attachments)
   - Base64-encodes the MIME message
   - POST to Gmail API `/drafts` endpoint with `raw` message
   - Returns draft ID
6. Go sends `NativeDraftCreatedMessage` back to extension
7. Service worker records draft in `recentDrafts`, removes email from queue, sends notification
8. Popup updates badge and notifies user

**User Interaction (Popup):**

1. Popup renders email list from `emails` Map
2. User clicks email → shows `EmailDetail` with recipients, body, attachments
3. User clicks "Save as Draft" → calls `chrome.runtime.sendMessage({ action: 'createDraft', id: ... })`
4. Service worker handles, follows draft creation flow above
5. Or user clicks "Delete" → calls `chrome.runtime.sendMessage({ action: 'deleteEmail', id: ... })`
6. Service worker sends `NativeDeleteMessage` to Go
7. Go deletes file, sends `NativeRemoved` back, popup updates

**State Persistence:**

- Emails: Stored in `chrome.storage.session.emails` (Map<string, EmailWithId>)
- Recent drafts: Stored in `chrome.storage.session.recentDrafts` (array of 20 most recent)
- On service worker restart: `loadState()` retrieves from session storage
- On email or draft action: `persistEmails()` or `persistDrafts()` writes back

## Key Abstractions

**MailMessage:**
- Purpose: Unified email data structure across all layers
- Examples: `src/native-host/protocol.go` (Go struct), `src/extension/src/types/messages.ts` (TypeScript interface)
- Pattern: Defined in protocol, mirrored in extension for type safety; Go and TypeScript implementations must stay in sync

**EmailWatcher:**
- Purpose: Encapsulates filesystem monitoring and file-to-ID mapping
- Location: `src/native-host/watcher.go`
- Pattern: Single goroutine watching directory, debouncing writes, maintaining in-memory state
- Methods: `Start()`, `Stop()`, `GetEmails()`, `MarkProcessed()`, `Delete()`

**GmailClient:**
- Purpose: Encapsulates Gmail API operations
- Location: `src/native-host/gmail.go`
- Pattern: Single responsibility — only creates drafts, builds MIME locally, handles auth errors
- Uses `http.Client` directly; no Google SDK dependency

**NativeMessaging:**
- Purpose: Protocol handler for Chrome native messaging
- Location: `src/native-host/protocol.go`
- Pattern: Read/Write methods handle 4-byte framing, JSON marshaling
- Stateless: Can be tested with mock readers/writers

**Service Worker State:**
- Purpose: Central hub for connection, email queue, notifications
- Location: `src/extension/src/background/service-worker.ts`
- Pattern: Global maps for `emails`, `recentDrafts`; connection state stored separately
- Messaging: Broadcasts state changes to popup via `chrome.runtime.sendMessage()`

## Entry Points

**Windows Application → DLL:**
- Location: `src/interceptor/main.cpp` (DLL entry point)
- Triggers: App calls `MAPISendMail()` or `MAPISendMailW()` on mapi32.dll
- Responsibilities: Load DLL, initialize logging/file paths, export MAPI functions

**Native Host Start:**
- Location: `src/native-host/main.go`
- Triggers: Chrome extension calls `chrome.runtime.connectNative('com.gomapi.host')`
- Responsibilities: Initialize logging, create file watcher, connect stdin/stdout, handle message loop
- Exits: On `MsgTypeShutdown` or stdin EOF

**Extension Popup Open:**
- Location: `src/extension/src/popup/main.tsx`
- Triggers: User clicks extension icon
- Responsibilities: Render App component, fetch initial emails via `chrome.runtime.sendMessage({ action: 'getEmails' })`

**Service Worker Startup:**
- Location: `src/extension/src/background/service-worker.ts` (bottom of file)
- Triggers: Browser loads extension
- Responsibilities: Load persisted state, update badge, connect to native host, set up listeners for alarms/messages/notifications

## Error Handling

**Strategy:** Three-level fallback with logging and user notification

**DLL Layer (C++):**
- Parse errors: Write to `%TEMP%\go-mapi\errors\{filename}` with `.error` file
- File write errors: Return to calling app (silent; MAPI errors don't block app)
- Logging: Writes to `%TEMP%\go-mapi\native-host.log`

**Native Host (Go):**
- File read errors: Retry 3 times with 200ms backoff (handles AV software locking)
- JSON parse errors: Move to errors folder, log
- Validation errors: Move to errors folder with reason
- Network errors: Log; send to extension via `SendError()` message
- OAuth token errors: Return `draft-error` with error message, display notification

**Extension (TypeScript):**
- Native host disconnection: Retry connection every 6 seconds with alarm
- Auth failure: Show notification "Sign in required", wait for user action
- Draft creation failure: Catch errors, show notification, keep email in queue
- Network/API errors: Send to background console, display in popup as error alert

## Cross-Cutting Concerns

**Logging:**
- Approach: File-based for native components (DLL writes to `%TEMP%`, Go writes to `native-host.log`), console for extension
- Pattern: Timestamp + level (INFO/ERROR) + message
- Go logging functions: `logInfo()` and `logError()` in `main.go`
- Extension: `console.log()` and `console.error()` with `[go-mapi]` prefix

**Validation:**
- Approach: Validate at boundary layers
- Go: `validateMailMessage()` checks version, timestamp, bodyFormat, recipient addresses
- TS: Type checking via TypeScript interfaces; runtime checks in React components
- DLL: MAPI structure parsing; rejects invalid message structures

**Authentication:**
- Approach: OAuth 2.0 via Chrome Identity API + token passing to Go
- Chrome handles token refresh; Go passes token as Bearer in Authorization header
- No token storage: Token is ephemeral, obtained per draft creation request
- Gmail API scopes: `https://www.googleapis.com/auth/gmail.compose` and `gmail.send`

**Privacy & Data Handling:**
- Approach: Delete-on-process, no long-term storage
- DLL: No logging of message content
- Go: Deletes JSON file after email processes (file removal in `MarkProcessed()`)
- Extension: Session storage only (cleared on browser restart)
- No network calls except to Gmail API

---

*Architecture analysis: 2026-04-10*
