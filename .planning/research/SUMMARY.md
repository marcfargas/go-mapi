# Project Research Summary

**Project:** go-mapi v3.0 Wails Pivot
**Domain:** Windows desktop tray app - MAPI-to-Gmail bridge (Go + WebView2)
**Researched:** 2026-04-12
**Confidence:** MEDIUM-HIGH overall

---

## Executive Summary

go-mapi v3.0 replaces the Chrome extension + native-host architecture with a standalone Wails desktop application (Go backend + WebView2 frontend) that lives in the Windows system tray. The core value proposition is unchanged - Windows Send to Mail recipient calls become Gmail drafts - but the distribution model simplifies dramatically: one installer, no browser extension, no Chrome Web Store dependency, no manifest registration. The MAPI interceptor DLL remains; everything above it is rebuilt.

The recommended stack is **Wails v2.12.0 stable** (not v3 alpha) combined with **fyne.io/systray v1.12.0 RunWithExternalLoop** for tray integration. Three of four researcher agents converged on this; the lone dissenter (ARCHITECTURE.md) recommended v3 alpha but conflated Wails v2 will not natively add systray (true) with systray is impossible on v2 (false). The RunWithExternalLoop pattern resolves the integration gap without alpha-channel risk. OAuth moves from Chrome Identity API to a PKCE loopback redirect via golang.org/x/oauth2, with tokens persisted in Windows Credential Manager via go-keyring.

The project faces one unresolved structural constraint: PROJECT.md targets 10-30 MB RAM per instance for RDS viability, but PITFALLS.md measures WebView2 at 80-150 MB in practice. WebView2 process groups cannot be shared across HDESKTOP-isolated RDS user sessions - this is a hard platform boundary, not a tuning parameter. Phase 1 must include a measurement gate before any OAuth or feature work proceeds. If RAM exceeds 80 MB per session in tray-only mode with lazy WebView2 init, the Wails approach requires re-evaluation.

---

## Key Findings

### Stack (from STACK.md)

| Technology | Version | Rationale |
|---|---|---|
| Wails | v2.12.0 | Stable; v3 is nightly alpha with known tray race bugs |
| fyne.io/systray | v1.12.0 | RunWithExternalLoop integrates with Wails v2 message loop; getlantern/systray conflicts |
| golang.org/x/oauth2 | v0.36.0 | PKCE S256ChallengeOption; loopback redirect; no embedded server needed |
| go-keyring (zalando) | v0.2.8 | DPAPI-backed; Windows Credential Manager; no plaintext storage |
| go-selfupdate (creativeprojects) | v1.5.2 | Version-detect-and-notify only; no binary replacement (EXE locked in Program Files) |
| Svelte 5 | latest stable | Compiles to zero-runtime JS; matters at 30 concurrent RDS renderer processes vs React 42 KB |
| WebView2 | Evergreen Bootstrapper | Pins WebView2 at install time; bootstrapper timing bug on servers - test on clean offline VM |
| Go | 1.23 | Bump from 1.21; Wails v2 is sensitive to Go version; build 64-bit only |

**Critical version constraint:** Go must be pinned at 1.23. Wails v2 fails silently on some 1.24 builds.

**Tray implementation pattern (from STACK.md):**
```go
start, end := systray.RunWithExternalLoop(onTrayReady, onTrayExit)
// called from Wails OnStartup:
start()
// called from Wails OnShutdown:
end()
```

### Features (from FEATURES.md)

**Table stakes (must ship in v3.0):**
- System tray: persistent icon, right-click menu, left-click window toggle, minimize-to-tray, two icon states (idle / error)
- Toast notifications: WinRT (not NIIF_INFO balloons); AppUserModelID required for persistent Action Center toasts
- Desktop OAuth: PKCE loopback, re-auth on 401, sign-in/sign-out menu items
- Automode: Manual (user clicks Create Draft) and Auto-draft (automatic on arrival); Auto-send deferred
- Autoupdate: notify-only (no in-process replacement); check on startup + daily
- NSIS installer: AppUserModelID + Start menu shortcut, Firewall inbound rule, v2.x artifact cleanup

**Differentiators (v3.0 if time permits):**
- Offline queue (queue emails when no network; drain on reconnect)
- Settings UI (automode toggle, notification prefs, sign-out)
- Draft preview before auto-send (irreversibility guard)

**Explicitly deferred to v4+:**
- Auto-send (irreversibility risk for unverified users)
- Multi-account support
- SMTP fallback
- macOS/Linux

**Feature dependency graph (critical for phase ordering):**
- Toasts require AppUserModelID - installer must come before or with toast work
- Automode requires OAuth
- Installer enables OAuth (AUMID shortcut registration)
- Autoupdate requires installer (stable install path)

### Architecture (from ARCHITECTURE.md)

**Major structural change:** src/native-host/ absorbed into src/app/ (Wails app). src/extension/ becomes src/app/frontend/ (Svelte). The MAPI interceptor DLL (src/interceptor/) is unchanged.

**Key components:**
- App struct (Go): Bound to Wails runtime; exposes GetQueue, CreateDraft, DeleteEmail, SignIn, SignOut, GetAuthStatus, GetSettings, SaveSettings, CheckForUpdate
- Watcher (watcher.go): Filesystem watcher unchanged; WatcherCallback replaces *NativeMessaging dependency
- GmailClient (gmail.go): Unchanged core; add 30s timeout + 3-retry exponential backoff (currently has neither)
- State: In-memory queue (Go process), keyring tokens (Windows Credential Manager), %APPDATA%/go-mapi/settings.json; frontend is ephemeral
- Window lifecycle: Hidden: true, HiddenOnTaskbar: true at startup; intercept WindowClosing to call window.Hide() not quit

**Event channels (Wails runtime events):** queue-update, auth-changed, draft-created, update-available, error

**Single-instance guard:** Named mutex (CreateMutex) at startup - two lines, prevents duplicate draft creation from double-click.

**WM_QUERYENDSESSION:** Requires hidden message-only HWND separate from Wails window (Wails v2 does not expose logoff hook).

**Architecture note on ARCHITECTURE.md dissent:** That file recommends Wails v3 alpha. Do not use. Single-instance is met with a named mutex in v2, simpler and more reliable.

**Minor library conflict:** ARCHITECTURE.md uses github.com/99designs/keyring; STACK.md uses github.com/zalando/go-keyring. Use zalando - simpler API, Windows-native DPAPI, no CGo.

### Pitfalls (from PITFALLS.md)

**Critical pitfalls (project-blocking if ignored):**

| # | Pitfall | Prevention |
|---|---|---|
| 1 | WebView2 RAM 80-150 MB per session (not 10-30 MB) | Phase 1 measurement gate; lazy WebView2 init |
| 3 | Google OAuth 100-user lifetime cap for unverified apps | Submit verification at Phase 2 START (4-8 week review) |
| 7 | Wails v2 tray race: blank flash, multiple instances | Named mutex; Hidden: true + WindowHide() from OnStartup |
| 10 | SmartScreen zero reputation (new binary name) | Submit to Microsoft WDSI after first public release |

**High-priority pitfalls:**

| # | Pitfall | Prevention |
|---|---|---|
| 4 | OAuth loopback Windows Firewall prompt on RDS | Pre-create inbound rule in NSIS installer; use 127.0.0.1 not localhost |
| 8 | Self-update: EXE locked in Program Files | Notify-only autoupdate; re-run installer for actual update |
| 9 | v2.x artifact cleanup on upgrade | NSIS installer removes native messaging manifests; clears registry |
| 12 | Gmail API no timeout, no retry | Add 30s http.Client timeout; 3-retry exponential backoff |

**Moderate pitfalls:**

| # | Pitfall | Prevention |
|---|---|---|
| 2 | WebView2 bootstrapper timing bug on offline/server machines | Test on clean offline VM; bundle offline installer as fallback |
| 5 | OAuth refresh token silent invalidation | Implement 401-triggered re-auth; surface Sign in required notification |
| 6 | DPAPI credentials do not roam on RDS farms | Document re-auth per server; warn in installer for RDS deployments |
| 11 | Wails v2 Go version sensitivity | Pin Go 1.23; build 64-bit only |

---

## Implications for Roadmap

### Suggested Phase Structure

The dependency graph and pitfall severity dictate a 5-phase structure. The critical path runs: RAM validation to OAuth to feature completion to installer to release hardening.

---

**Phase 1: Wails Shell + RAM Measurement Gate**

Rationale: Nothing else can proceed until we know if WebView2 is viable for the RDS constraint. Build the minimal Wails app with tray integration and measure RAM before writing any business logic.

Delivers:
- Wails v2.12.0 + fyne.io/systray v1.12.0 integrated (RunWithExternalLoop pattern)
- App starts hidden, tray icon appears, right-click menu has Quit
- Single-instance named mutex guard
- Window show/hide on tray left-click
- WM_QUERYENDSESSION hidden HWND
- RAM measurement: tray-only mode (no OAuth, no watcher) on RDS and workstation

Gate: RAM <= 80 MB per session in tray-only mode with lazy WebView2 init. If above threshold, halt and re-evaluate. Do not proceed to Phase 2 without passing this gate.

Features from FEATURES.md: System tray (table stakes - partial)
Pitfalls to avoid: #1 (RAM), #7 (tray race), #11 (Go version)
Research flag: YES - spike needed: fyne.io/systray RunWithExternalLoop integration with Wails v2; document working pattern before phase begins

---

**Phase 2: OAuth + Credential Storage**

Rationale: OAuth is the dependency for all email features. Start Google verification request on day 1 of this phase - the 4-8 week review window means waiting costs launch weeks.

Delivers:
- PKCE loopback OAuth flow (golang.org/x/oauth2 v0.36.0, S256ChallengeOption)
- Token storage via go-keyring (Windows Credential Manager / DPAPI)
- Sign In / Sign Out tray menu items
- 401-triggered re-auth notification (Sign in required)
- Google OAuth verification request submitted

Features from FEATURES.md: Desktop OAuth (table stakes)
Pitfalls to avoid: #3 (100-user cap), #4 (RDS firewall - stub firewall rule for dev), #5 (silent invalidation), #6 (DPAPI roaming)
Research flag: NO - PKCE loopback is well-documented in golang.org/x/oauth2

---

**Phase 3: Email Queue + Automode + Toasts**

Rationale: Core feature work. Watcher and Gmail client already exist; adapt them to the App struct. WinRT toasts require AppUserModelID which will be set up in Phase 4 installer - use a dev AppUserModelID for Phase 3 testing.

Delivers:
- FileWatcher adapted (WatcherCallback replacing NativeMessaging)
- GmailClient with 30s timeout + 3-retry exponential backoff
- Email queue UI (Svelte frontend)
- Manual mode: user clicks Create Draft per email
- Auto-draft mode: automatic on arrival
- WinRT toast notifications on email arrival and draft creation
- Settings persistence (%APPDATA%/go-mapi/settings.json)

Features from FEATURES.md: Automode (table stakes), toasts (table stakes), settings UI (differentiator)
Pitfalls to avoid: #12 (Gmail timeout/retry), #7 (window flash on notification click)
Research flag: YES - WinRT toast library selection (go-toast vs go10ft/toast vs direct COM); AppUserModelID registration approach

---

**Phase 4: NSIS Installer**

Rationale: Installer must come before release. It retroactively fixes Phase 3 gaps: AppUserModelID enables persistent Action Center toasts; Firewall rule eliminates RDS OAuth dialog. Handles v2.x cleanup.

Delivers:
- NSIS installer (.exe) with:
  - AppUserModelID + Start menu shortcut (persistent Action Center toasts)
  - Windows Firewall inbound rule (OAuth loopback, no RDS dialog)
  - v2.x cleanup: native messaging manifests removed, MAPI registry cleared, extension unregistered
  - MAPI interceptor DLL registration
  - WebView2 Evergreen Bootstrapper (offline fallback bundled)
- Uninstaller
- Installer tested on: Windows 10/11 workstation, Windows Server 2019/2022 RDS

Features from FEATURES.md: NSIS installer (table stakes)
Pitfalls to avoid: #2 (WebView2 bootstrapper offline), #4 (Firewall rule), #9 (v2.x cleanup), #10 (SmartScreen - include guidance in installer)
Research flag: NO - NSIS patterns are well-documented for Wails apps

---

**Phase 5: Autoupdate + Release Hardening**

Rationale: Final phase. Autoupdate is notify-only (no binary replacement). SmartScreen submission happens after first public binary is signed and released. Confirm Google OAuth verification completed before public launch.

Delivers:
- go-selfupdate v1.5.2 integration: check on startup + daily alarm
- Update available tray menu item + notification
- Update installs by re-running installer download
- GitHub release pipeline (build, sign if available, upload)
- SmartScreen WDSI submission
- Google OAuth verification confirmed (or contingency plan if still pending)
- End-to-end smoke test: MAPI trigger to DLL to watcher to auto-draft to Gmail draft visible

Features from FEATURES.md: Autoupdate notify-only (table stakes)
Pitfalls to avoid: #8 (EXE locked / binary replacement), #10 (SmartScreen)
Research flag: NO - autoupdate pattern is straightforward with go-selfupdate

---

### Cross-Phase Constraints

- **Google OAuth verification:** Submit at Phase 2 START. If not submitted until Phase 4-5, launch will be blocked by the 4-8 week review window.
- **AppUserModelID:** Must be registered by installer (Phase 4) for persistent Action Center toasts. Phase 3 tests toasts with a dev AUMID; Phase 4 makes it permanent.
- **RAM gate is a hard stop:** Phase 1 result determines whether Phases 2-5 proceed as designed. No parallel work on OAuth or features while the gate is unmeasured.

---

## Confidence Assessment

| Area | Confidence | Notes |
|---|---|---|
| Stack | HIGH | 3:1 consensus on Wails v2 + fyne.io/systray; all library choices have production precedents |
| Features | HIGH | Clear table stakes vs differentiator vs deferred split; dependency graph well-mapped |
| Architecture | MEDIUM | Core patterns solid; Wails v2-specific window lifecycle needs spike to confirm |
| Pitfalls | HIGH | RAM measurement is the only unresolved item; all other pitfalls have concrete prevention strategies |

**Overall: MEDIUM-HIGH**

### Gaps to Address in Planning

1. **RAM constraint validation (Phase 1 gate):** No measurement exists. The 10-30 MB target in PROJECT.md may need to be revised or the approach changed. Highest-priority unknown.

2. **fyne.io/systray + Wails v2 integration spike:** RunWithExternalLoop is documented but go-mapi has no existing Wails code. A working prototype must be built and the pattern documented before Phase 1 completes.

3. **WinRT toast library selection:** Three Go libraries exist (go-toast, go10ft/toast, direct COM via golang.org/x/sys). None have been benchmarked for AppUserModelID support and Action Center persistence. Resolve in Phase 3 research.

4. **Google OAuth verification timeline:** 4-8 week external dependency. If submission is delayed, it becomes the critical path item for launch. Treat as project risk from Phase 2 onward.

---

## Sources

STACK.md - Technology recommendations with version rationale; tray integration patterns; Go version constraints; Svelte vs React comparison for RDS.

FEATURES.md - Table stakes definition; differentiator vs deferred split; feature dependency graph; MVP scope; WinRT toast AppUserModelID requirement; automode design (Manual + Auto-draft, no Auto-send).

ARCHITECTURE.md - Directory structure migration plan; App struct bound methods; event channel names; state location decisions; window lifecycle patterns. Note: this file recommends Wails v3 alpha - recommendation overridden by 3:1 consensus; use Wails v2.12.0.

PITFALLS.md - 12 pitfalls with severity ratings and prevention strategies; WebView2 RAM measurement (80-150 MB per session); Google OAuth 100-user cap; RDS-specific constraints; SmartScreen reputation zero-start.

PROJECT.md - v3.0 milestone scope; RAM budget constraint (10-30 MB target - flagged as constraint-to-validate-early vs PITFALLS.md measurement); out-of-scope items.

Architecture re-eval note (2026-04-12-architecture-reeval-wails.md) - Seed decision motivating the Wails pivot; confirms 30x10-30 MB as target, 30x200 MB as unacceptable.
