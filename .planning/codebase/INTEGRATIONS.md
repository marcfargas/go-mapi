# External Integrations

**Analysis Date:** 2026-04-10

## APIs & External Services

**Gmail API:**
- Service: Google Gmail API v1 (`https://www.googleapis.com/gmail/v1/users/me`)
- What it's used for: Create email drafts with attachments from MAPI sends
- SDK/Client: Custom HTTP client in `src/native-host/gmail.go` (not using official Google SDK)
- Auth: OAuth 2.0 token from Chrome Identity API (passed from extension to native host)
- Endpoint: `POST https://www.googleapis.com/gmail/v1/users/me/drafts` for draft creation
- Message Format: RFC 2822 MIME messages with base64url encoding
- Attachment handling: Full MIME multipart messages built locally (single API call, no separate attachment API)

## Data Storage

**Files:**
- Location: Temporary directory (`%TEMP%\go-mapi\`)
- What: JSON files representing intercepted emails (MAPI message structure)
- Lifecycle: Created by interceptor DLL, watched by native host, deleted after processing or manual removal
- No database — file-based IPC between DLL and native host

**Browser Storage:**
- Session storage via `chrome.storage.session` (extension only)
- Stores: Current email list, recent drafts list
- No persistence across extension reloads by design

**No Database Backend:**
- Completely stateless
- State lives in `%TEMP%\go-mapi\` JSON files and extension memory

## Authentication & Identity

**Auth Provider:**
- Google OAuth 2.0 via Chrome Identity API
- Implementation: Extension uses `chrome.identity.getAuthToken()` for OAuth token acquisition
- Scope: `gmail.compose`, `gmail.send`
- OAuth Client: Embedded in extension manifest (`src/extension/public/manifest.json`)
  - Client ID: `757265040228-u6jlcde97info3c331di4s3gqsr1251q.apps.googleusercontent.com`
  - Type: Chrome Extension OAuth client (restricted to extension ID)
- Token Refresh: Handled automatically by Chrome
- Token Passing: Extension passes token to native host via Native Messaging protocol for draft creation
- Non-interactive fallback: Attempts `getAuthToken({interactive: false})` before requiring user interaction

## Monitoring & Observability

**Logging:**
- Native host logs to file: `%TEMP%\go-mapi\native-host.log`
- Format: ISO8601 timestamp + [LEVEL] + message
- Levels: INFO, ERROR
- Logging location: `src/native-host/main.go` (`initLogging()`, `logInfo()`, `logError()`)
- Extension logs to browser console (Chrome DevTools)

**Error Tracking:**
- No external error tracking service (local logging only)
- Extension shows error notifications via `chrome.notifications` API
- Native host sends error messages back to extension via Native Messaging protocol

## CI/CD & Deployment

**Hosting:**
- GitHub Releases (`https://github.com/marcfargas/go-mapi/releases`)
- Installation script downloads binaries from GitHub releases
- Windows only (MAPI is Windows-specific)

**Package Managers:**
- NPM/npm registry for extension dependencies
- No official package distribution for DLL/native host (distributed as part of GitHub release)

**Installation Method:**
- PowerShell script-based installation (`scripts/install.ps1`)
- Script auto-detects extension ID from browser profiles
- Downloads latest/specified release from GitHub
- Registers DLL in Windows Registry as MAPI handler
- Sets up native messaging manifest for Chrome and Edge
- No SCCM/Intune native support, but script can be called from Intune/SCCM

## Environment Configuration

**Required Env Vars:**
- None required at runtime (Windows Registry provides all configuration)
- Build-time: Standard Go/Node/cmake environment

**Configuration Sources:**
- Windows Registry: `HKLM:\SOFTWARE\Clients\Mail\go-mapi`
  - Stores: DLL path, native host executable path, extension ID
  - Set during installation via `install.ps1`
- Native Messaging Manifest: `$env:APPDATA\Google\Chrome\NativeMessagingHosts\com.gomapi.host.json` and equivalent for Edge
  - Stores: Native host executable path for this specific extension
  - Generated during installation

**No Secrets in Code:**
- OAuth client ID embedded in manifest (public, not a secret)
- OAuth token obtained at runtime from Chrome (not stored)
- No API keys or credentials in source code

## Webhooks & Callbacks

**Incoming Webhooks:**
- None — no external services call back to go-mapi

**Outgoing Webhooks:**
- None — go-mapi does not POST to external services
- Gmail API is only outbound integration (standard REST API, not webhook)

## Windows-Specific Integrations

**MAPI Handler Registration:**
- Location: `HKLM:\SOFTWARE\Clients\Mail\go-mapi`
- Protocol: SimpleMAPI (`MAPISendMail()` function)
- How triggered: File Explorer "Send to → Mail recipient" calls DLL
- DLL exports: MAPI functions via `src/interceptor/mapi_exports.def`

**File System Monitoring:**
- Watched directory: `%TEMP%\go-mapi\`
- Technology: fsnotify library (wraps Windows ReadDirectoryChangesW)
- Purpose: Detect new email JSON files written by interceptor DLL
- No polling (event-driven)

**Chrome Native Messaging:**
- Protocol: Chrome Native Messaging (4-byte length prefix + JSON)
- Bi-directional communication: extension ↔ native host
- Message types: `create-draft`, `draft-created`, `draft-error`, `email`, `removed`, `list`, `process`, `delete`, `shutdown`
- Implementation: `src/native-host/protocol.go` (`NativeMessaging` type)
- Connection lifecycle: Extension initiates via `chrome.runtime.connectNative()`

## Version Compatibility

**Browser Support:**
- Chrome 90+
- Edge 90+ (Chromium-based)
- Extension uses Manifest v3 (latest standard)

**Gmail API Version:**
- Gmail API v1 (current stable version)
- No versioning issues — API endpoint is stable

**Go Version:**
- Requires Go 1.21+ (for range over integer, iter patterns)

**Windows Version:**
- Windows 10/11 (MAPI available on all modern Windows)
- Registry and file system APIs used are stable across Windows versions

## Message Flow (Native Messaging Protocol)

```
Windows App
    ↓ MAPISendMail()
Interceptor DLL (go-mapi.dll)
    ↓ writes JSON to %TEMP%\go-mapi\*.json
Native Host (go-mapi-host.exe)
    ↓ watches directory, detects new files
Browser Extension (popup.html + service-worker.js)
    ↓ chrome.runtime.connectNative('com.gomapi.host')
    ↑↓ Native Messaging protocol (4-byte length + JSON)
    ↓ gets OAuth token via chrome.identity.getAuthToken()
Gmail API (REST)
    ↓ POST /drafts with RFC 2822 MIME message
Gmail (Draft created)
```

---

*Integration audit: 2026-04-10*
