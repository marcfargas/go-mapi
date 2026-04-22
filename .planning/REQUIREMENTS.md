# Requirements: go-mapi

**Defined:** 2026-04-12
**Core Value:** A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.

## v3.0 Requirements (Wails Pivot)

Requirements for the v3.0 milestone — standalone Wails desktop app replacing the Chrome/Edge extension. Numbering continues from v2.x; categories map to roadmap phases.

### Shell (Wails desktop app)

- [ ] **SHELL-01**: Wails v2.12.0 app builds and runs on Windows 10/11 with WebView2 Evergreen runtime present
- [ ] **SHELL-02**: System tray icon appears on app start; left-click toggles main window visibility; right-click shows context menu (Show / Pause watching / Quit)
- [ ] **SHELL-03**: Main window shows current email queue and is closable without quitting the app (close button hides to tray)
- [ ] **SHELL-04**: Named mutex prevents multiple running instances; second launch raises the existing window
- [ ] **SHELL-05**: App exits cleanly on Windows logoff / shutdown (handles `WM_QUERYENDSESSION` / session-end events)
- [ ] **SHELL-06**: Existing file watcher (fsnotify of `%TEMP%\go-mapi\`) folds into the Wails app and runs whether the window is visible or hidden
- [ ] **SHELL-07**: Tray icon reflects queue state visually (idle / has-queue / error) with pre-rendered icon variants

### OAuth & Credentials

- [ ] **AUTH-01**: First-run prompts user to sign in via Google OAuth desktop flow (loopback redirect to `127.0.0.1` on ephemeral port, PKCE S256)
- [ ] **AUTH-02**: System browser opens for consent; embedded webview is explicitly NOT used
- [x] **AUTH-03**: Refresh token stored via `99designs/keyring` (Windows Credential Manager backend) — no plaintext on disk
- [ ] **AUTH-04**: Access token refreshes transparently when Gmail API returns 401; user is not prompted mid-action
- [ ] **AUTH-05**: `invalid_grant` on refresh triggers re-auth flow (not retry loop); user sees a clear re-sign-in prompt
- [x] **AUTH-06**: New GCP project / OAuth client registered for the desktop app flow; verification submission filed on Phase 2 day 1 (sensitive scopes: `gmail.compose`, `gmail.send`)
- [ ] **AUTH-07**: "Sign out" control in the main window clears the stored token

### Queue, Actions & Automode

- [ ] **QUEUE-01**: Main window lists all emails in the queue with sender, subject, attachment count, timestamp (parity with current extension popup)
- [ ] **QUEUE-02**: Per-email "Create draft" action invokes existing Gmail draft flow (Go code from `src/native-host/gmail.go` reused)
- [ ] **QUEUE-03**: Per-email "Dismiss" action removes the file from `%TEMP%\go-mapi\` without creating a draft
- [ ] **QUEUE-04**: Global mode toggle with two options: **Manual** (default — user action required per email), **Auto-draft** (every new queued email becomes a Gmail draft automatically); setting persists across restarts
- [ ] **QUEUE-05**: Auto-draft runs in the Go goroutine layer so it processes queue items even when the window is hidden
- [ ] **QUEUE-06**: Failed auto-draft actions keep the email in the queue, surface an error state, and notify the user — they do not silently drop
- [ ] **QUEUE-07**: Queue updates push to the frontend via Wails event channel when `%TEMP%\go-mapi\` changes (no polling in the UI)

### Notifications

- [ ] **NOTIF-01**: New queued emails trigger a Windows toast notification (Action Center compatible)
- [ ] **NOTIF-02**: Toast content shows sender + subject + attachment count only (no body text — privacy)
- [ ] **NOTIF-03**: Toast action buttons: "Create draft" and "Dismiss" — both work without opening the main window
- [ ] **NOTIF-04**: AppUserModelID registered at install time with a Start Menu shortcut so toasts persist in Action Center
- [ ] **NOTIF-05**: Toasts for processed emails are removed from Action Center when the underlying email is drafted/dismissed

### Installer & Migration

- [ ] **INST-01**: Signed (SignPath) installer produces a single `.exe` installer that registers the MAPI handler, places the DLL, installs the Wails app binary, and registers the AppUserModelID shortcut
- [ ] **INST-02**: Installer detects and bootstraps WebView2 Evergreen runtime if absent; fails loudly with a link to Microsoft's runtime page if the bootstrapper cannot reach the network (e.g., locked-down corporate servers)
- [ ] **INST-03**: Installer detects prior v2.x artifacts (native host binary, native messaging manifests in `%APPDATA%\Google\Chrome\NativeMessagingHosts\` and Edge equivalents) and removes them as part of setup
- [ ] **INST-04**: Installer does NOT require admin privileges for the per-user install path; admin is only required for machine-wide install (RDS scenario)
- [ ] **INST-05**: Uninstall removes the Wails binary, MAPI handler, registry keys, AppUserModelID shortcut, and temp directory residue
- [ ] **INST-06**: Windows Firewall rule for loopback OAuth port is added during install (or handled transparently if user approves the prompt)
- [ ] **INST-07**: Pester 5 smoke test verifies install + uninstall round-trip on a fresh `windows-latest` runner (adapted from v2.0 pattern)

### Release & Autoupdate

- [ ] **REL-01**: Chrome/Edge extension listings are retired on v3.0 GA via frozen/deprecated Chrome Web Store and Edge Add-ons pages that redirect users to the desktop app, with proof of the store-side action captured
- [ ] **REL-02**: `go-mapi-setup.exe` published to stable URL `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`
- [ ] **REL-03**: In-app version check uses `creativeprojects/go-selfupdate` to query GitHub Releases on startup and once per 24h
- [ ] **REL-04**: When a newer version is available, app shows a tray notification with "Download" action that opens the release page in the browser — no in-process binary replacement
- [ ] **REL-05**: User can opt out of update checks via a settings toggle
- [ ] **REL-06**: End-to-end smoke test on Windows Sandbox: fresh install → sign-in → email queued via MAPI → draft created → uninstall clean
- [ ] **REL-07**: README rewritten to describe the v3.0 install + setup flow; v2.x is retired and not maintained as in-tree legacy documentation
- [ ] **REL-08**: An end-to-end Playwright/CDP harness drives the real Wails app + WebView2 against a fake Gmail endpoint and a fake keyring (under a `//go:build e2e` shim), with regression coverage for the Wails↔Svelte UI roundtrip class of bug — added 2026-04-22 after Phase 11 manual smoke caught queue-row staleness symptoms that Vitest with mocked bindings could not see

### Quality Gates (non-functional)

- [ ] **QUAL-01**: Per-instance RAM measured under RDS-like load (5–10 concurrent sessions on Windows Server) before Phase 2 begins; target ≤ 80 MB idle; original aspiration ≤ 30 MB noted as stretch goal
- [ ] **QUAL-02**: Wails app runs without Chrome or Edge browsers installed (only WebView2 runtime required)
- [x] **QUAL-03**: No telemetry, no content retention, no network calls outside Gmail API and GitHub Releases update check
- [x] **QUAL-04**: `go test -race ./...` green on the Wails app Go code (carries forward the v2.0 race-safety posture) — closed Phase 8.1 via per-PR -race gate in build-wails-app (D-07)

## Future Requirements (post-v3.0)

### Composer & Send

- **COMP-01**: In-app composer for editing drafts before send (not just queue review)
- **COMP-02**: Auto-send mode with 5–10s undo-send window
- **COMP-03**: SMTP backend (non-Gmail providers) via composer path

### Enterprise

- **ENT-01**: Managed deployment mode (MSI with admin-controlled policies)
- **ENT-02**: Centralized OAuth client provisioning (avoid per-install Google consent)
- **ENT-03**: Audit log for enterprise admins (opt-in, redacted content)

### Browser Independence

- **FF-01**: Formal Firefox validation (confirm no CWS/Edge dependencies remain anywhere in the flow)

## Out of Scope (v3.0)

| Feature | Reason |
|---------|--------|
| Auto-send without undo | Accidental-send risk too high; ship Manual + Auto-draft only in v3.0 |
| In-process binary self-update | Windows file-locking on running EXE; `go-selfupdate` notify-only is safer |
| In-app composer / editor | Non-trivial scope; preserved as v3.x |
| Outlook / Microsoft 365 support | Gmail-first milestone |
| Multi-account (pick which Gmail) | Deferred |
| SMTP / non-Gmail providers | Deferred — requires composer |
| Per-package CHANGELOG.md auto-generation | Deferred (OPS-03 from v2.1.0 carry-over) |
| Edge API / CWS API automation | Browser extension retiring — no longer needed |
| In-place upgrade from v2.x | Clean-break migration instead; users uninstall v2.x + install v3.0 |
| macOS / Linux support | MAPI is Windows-only |

## Traceability

Which phases cover which requirements. Updated by roadmapper 2026-04-12.

| Requirement | Phase | Status |
|-------------|-------|--------|
| SHELL-01 | Phase 7 | Pending |
| SHELL-02 | Phase 7, 9 | Complete |
| SHELL-03 | Phase 7 | Pending |
| SHELL-04 | Phase 7 | Pending |
| SHELL-05 | Phase 7 | Pending |
| SHELL-06 | Phase 7 | Pending |
| SHELL-07 | Phase 7, 9 | Complete |
| AUTH-01 | Phase 8 | Pending |
| AUTH-02 | Phase 8 | Pending |
| AUTH-03 | Phase 8 | Complete |
| AUTH-04 | Phase 8 | Pending |
| AUTH-05 | Phase 8 | Pending |
| AUTH-06 | Phase 8 | Complete |
| AUTH-07 | Phase 8 | Pending |
| QUEUE-01 | Phase 9 | Complete |
| QUEUE-02 | Phase 9 | Complete |
| QUEUE-03 | Phase 9 | Complete |
| QUEUE-04 | Phase 9 | Complete |
| QUEUE-05 | Phase 9 | Complete |
| QUEUE-06 | Phase 9 | Complete |
| QUEUE-07 | Phase 9 | Complete |
| NOTIF-01 | Phase 9 | Complete |
| NOTIF-02 | Phase 9 | Complete |
| NOTIF-03 | Phase 9 | Complete |
| NOTIF-04 | Phase 9 | Complete |
| NOTIF-05 | Phase 9 | Complete |
| INST-01 | Phase 10 | Pending |
| INST-02 | Phase 10 | Pending |
| INST-03 | Phase 10 | Pending |
| INST-04 | Phase 10 | Pending |
| INST-05 | Phase 10 | Pending |
| INST-06 | Phase 10 | Pending |
| INST-07 | Phase 10 | Pending |
| REL-01 | Phase 11 | Pending |
| REL-02 | Phase 11 | Pending |
| REL-03 | Phase 11 | Pending |
| REL-04 | Phase 11 | Pending |
| REL-05 | Phase 11 | Pending |
| REL-06 | Phase 11 | Pending |
| REL-07 | Phase 11 | Pending |
| QUAL-01 | Phase 7 | Pending |
| QUAL-02 | Phase 7 | Pending |
| QUAL-03 | Phase 8 | Complete |
| QUAL-04 | Phase 8.1 | Complete |

**Coverage:**
- v3.0 requirements: 44 total (note: original count of 43 was off by one — all categories re-counted from requirements text)
- Mapped to phases: 44
- Unmapped: 0 ✓

---
*Requirements defined: 2026-04-12*
*Last updated: 2026-04-12 — traceability table filled by roadmapper; all 44 requirements mapped to phases 7-11*
