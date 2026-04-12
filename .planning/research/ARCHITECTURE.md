# Architecture Research

**Domain:** Wails v3 desktop app — folding Go native-host into a Wails shell with system tray
**Researched:** 2026-04-12
**Confidence:** HIGH for Wails v3 API shape (verified against pkg.go.dev and official examples). MEDIUM for RDS RAM profile (no authoritative per-session measurement found — must be measured). MEDIUM for OAuth loopback flow (well-documented pattern, implementation details need integration testing). LOW for autoupdate installer-replacement strategy on Windows (no canonical Wails-specific approach; must use go-selfupdate or similar).

---

## Critical Decision: Wails v2 vs v3

**Use Wails v3 (alpha).** Wails v2 does not support system tray — confirmed by the Wails maintainers (GitHub Discussion #4514: "we are not supporting systray in v2"). System tray is a hard requirement for go-mapi (the app must persist in the background without a browser). Wails v3 has built-in systray support with Windows-verified examples (systray-basic, systray-menu at alpha.74). The API is "reasonably stable, applications running in production." Accept the alpha risk; the alternative (v2 + third-party tray glue) is more fragile and unsupported.

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                  UNCHANGED: MAPI Interception                    │
│  Windows App → MAPISendMail() → go-mapi.dll (C++) → JSON file   │
│                         %TEMP%\go-mapi\{uuid}.json              │
└──────────────────────────────────┬──────────────────────────────┘
                                   │ fsnotify (file events)
┌──────────────────────────────────▼──────────────────────────────┐
│                  NEW: Wails App (go-mapi.exe)                    │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Go Backend (main package)                                  │  │
│  │                                                              │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │  │
│  │  │ EmailWatcher │  │ GmailClient  │  │   AuthManager    │  │  │
│  │  │  (watcher.go)│  │  (gmail.go)  │  │   (auth.go NEW)  │  │  │
│  │  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘  │  │
│  │         │                 │                    │            │  │
│  │  ┌──────▼─────────────────▼────────────────────▼─────────┐  │  │
│  │  │            App struct (app.go)                          │  │  │
│  │  │  Bound methods → wailsjs/go/main/App.*                  │  │  │
│  │  │  GetQueue() []EmailWithId                               │  │  │
│  │  │  CreateDraft(id) DraftResult                            │  │  │
│  │  │  DeleteEmail(id) error                                  │  │  │
│  │  │  GetAuthStatus() AuthStatus                             │  │  │
│  │  │  SignIn() error                                         │  │  │
│  │  │  SignOut() error                                        │  │  │
│  │  └─────────────────────────────────────────────────────── ┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  WebView2 Frontend (React + TypeScript + Vite)             │  │
│  │  Calls App.* methods directly via wailsjs bindings         │  │
│  │  Receives events via EventsOn("queue-update", handler)     │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────┐   ┌────────────────────────────────────────────┐ │
│  │ SystemTray │   │  Window (hidden on start, shown on demand)  │ │
│  │  icon+menu │   │  HiddenOnTaskbar: true                      │ │
│  └────────────┘   └────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

---

## 1. Project Layout

### Recommended Layout: Wails App Absorbs Native-Host

Do NOT use `wails init` scaffold as-is. Instead, absorb the existing `src/native-host/` package into the Wails app directly. The extension is being removed, so the monorepo npm workspace structure shrinks but does not need to be eliminated.

**Target directory structure:**

```
go-mapi/
├── src/
│   ├── interceptor/          # UNCHANGED — C++ DLL
│   │   └── ...
│   │
│   ├── app/                  # NEW — Wails desktop app (replaces src/native-host/)
│   │   ├── main.go           # Wails app entry point (wails.Run, tray setup)
│   │   ├── app.go            # App struct — bound methods exposed to frontend
│   │   ├── watcher.go        # MOVED from src/native-host/watcher.go (minimal changes)
│   │   ├── gmail.go          # MOVED from src/native-host/gmail.go (minimal changes)
│   │   ├── auth.go           # NEW — OAuth2 loopback flow + keyring token storage
│   │   ├── updater.go        # NEW — autoupdate check (go-selfupdate)
│   │   ├── protocol.go       # KEPT but stripped — MailMessage/Recipients/Attachment types only
│   │   ├── frontend/         # NEW — React+Vite UI (replaces src/extension/)
│   │   │   ├── src/
│   │   │   │   ├── App.tsx
│   │   │   │   ├── components/
│   │   │   │   │   ├── EmailList.tsx
│   │   │   │   │   ├── EmailDetail.tsx
│   │   │   │   │   └── AuthPrompt.tsx
│   │   │   │   └── types/
│   │   │   │       └── email.ts  # mirrors Go EmailWithId shape
│   │   │   ├── package.json
│   │   │   ├── vite.config.ts
│   │   │   └── tsconfig.json
│   │   ├── build/            # Wails build resources (icons, manifests)
│   │   │   └── windows/
│   │   │       └── icon.ico
│   │   ├── wails.json        # Wails project config
│   │   ├── go.mod            # Module: github.com/marcfargas/go-mapi/app
│   │   └── go.sum
│   │
│   └── installer/            # STAYS — Inno Setup .iss script (updated targets)
│       └── go-mapi.iss
│
├── scripts/
│   ├── build-app.ps1         # NEW — builds Wails app (replaces build:native-host)
│   └── install.ps1           # UPDATED — installs Wails binary instead of native host
│
├── package.json              # Root workspace (shrinks — extension removed)
└── .github/workflows/
    └── build.yml             # UPDATED — Wails build target
```

### go.mod Placement

The Wails app has its own `go.mod` at `src/app/go.mod`. This is consistent with Wails scaffold convention: the Go module root is the directory that `wails build` runs from. The `wails.json` file sits alongside `go.mod`.

Do not put Wails' `go.mod` at the repository root — the root is still an npm workspace root and mixing Go module root with npm workspace root creates toolchain confusion.

### Module Name

```
module github.com/marcfargas/go-mapi/app
```

Matches the existing GitHub organization and project naming convention.

### Monorepo Status

The npm monorepo shrinks: `src/extension` workspace is removed. The root `package.json` retains workspace structure for `src/app/frontend` if npm tooling is used for the frontend build. If Wails handles all frontend building via `wails.json` `frontend:*` hooks, the npm workspace can be eliminated entirely and the root `package.json` becomes a thin build-scripts container.

**Recommendation:** Keep root `package.json` as build orchestration only. Remove `src/extension` from workspaces. Add `src/app/frontend` if npm scripts are needed outside Wails build. The `@changesets/cli` dependency is retained for v3.0 versioning.

---

## 2. Go Backend Boundary — What Gets Exposed vs. What Stays Internal

### Wails Binding Pattern

Wails v3 generates TypeScript bindings from exported methods on structs passed to `application.New(Options{Services: []*App})`. Any exported method on a bound struct is callable from the frontend as `App.MethodName(args)` in TypeScript.

### App struct — Bound Methods (public API to frontend)

```go
// app.go
type App struct {
    watcher *EmailWatcher
    gmail   *GmailClient   // created per-request with current token
    auth    *AuthManager
    ctx     context.Context
}

// GetQueue returns all emails currently in the watch directory.
// Called by frontend on mount and after queue-update events.
func (a *App) GetQueue() []EmailWithId

// CreateDraft creates a Gmail draft from the queued email.
// Returns draft URL on success. Removes email from queue on success.
func (a *App) CreateDraft(id string) (*DraftResult, error)

// SendEmail sends the email immediately via Gmail API.
// Returns message ID on success. Removes email from queue on success.
func (a *App) SendEmail(id string) (*SendResult, error)

// DeleteEmail removes an email from the queue without drafting.
func (a *App) DeleteEmail(id string) error

// GetAuthStatus returns whether a valid OAuth token is available.
func (a *App) GetAuthStatus() AuthStatus

// SignIn initiates the OAuth2 loopback flow (opens browser, waits for code).
func (a *App) SignIn() error

// SignOut revokes token and clears from keyring.
func (a *App) SignOut() error

// GetSettings returns current user-facing settings.
func (a *App) GetSettings() AppSettings

// SaveSettings persists settings to disk.
func (a *App) SaveSettings(settings AppSettings) error

// CheckForUpdate checks GitHub Releases for a newer version (opt-out autoupdate).
func (a *App) CheckForUpdate() (*UpdateInfo, error)
```

### Internal (not bound — no frontend access needed)

| Type/Function | Location | Reason Internal |
|---|---|---|
| `EmailWatcher` | `watcher.go` | Lifecycle managed by App; events pushed via Emit |
| `GmailClient` / `buildFullMIME()` | `gmail.go` | Created per-request by App methods; no direct frontend call |
| `validateMailMessage()` | `watcher.go` | Validation is an implementation detail |
| `normalizeAddress()` / `normalizeRecipients()` | `watcher.go` | Same |
| `AuthManager` | `auth.go` | Exposed only through `SignIn`, `SignOut`, `GetAuthStatus` |
| `generateID()` | `watcher.go` | Internal ID generation |
| `logInfo()` / `logError()` | `main.go` or `logging.go` | File-based logging; no frontend API |

### Data Types Exposed via Bindings

```go
// protocol.go — stripped to shared types only (no NativeMessaging)
type MailMessage struct { ... }    // unchanged
type Recipients  struct { ... }    // unchanged
type Recipient   struct { ... }    // unchanged
type Attachment  struct { ... }    // unchanged

// New types for App API surface
type EmailWithId struct {
    ID    string       `json:"id"`
    Email *MailMessage `json:"email"`
}

type DraftResult struct {
    DraftID  string `json:"draftId"`
    GmailURL string `json:"gmailUrl"`
}

type SendResult struct {
    MessageID string `json:"messageId"`
}

type AuthStatus struct {
    Authenticated bool   `json:"authenticated"`
    Email         string `json:"email,omitempty"`
}

type AppSettings struct {
    Mode        string `json:"mode"` // "auto-draft" | "auto-send" | "manual"
    UpdatesEnabled bool `json:"updatesEnabled"`
}

type UpdateInfo struct {
    Available bool   `json:"available"`
    Version   string `json:"version,omitempty"`
    URL       string `json:"url,omitempty"`
}
```

Wails v3 auto-generates TypeScript types for all these structs. The `wailsjs/` directory is generated at build time — do not hand-edit it.

---

## 3. Frontend/Backend Binding and Event Channels

### Method Calls (Frontend → Go)

Wails v3 generates bindings into `frontend/wailsjs/go/main/App.ts`. In TypeScript:

```typescript
import { GetQueue, CreateDraft, DeleteEmail, SignIn, GetAuthStatus } from '../wailsjs/go/main/App';

// Calling Go methods — all return Promises
const queue = await GetQueue();
const result = await CreateDraft(emailId);
```

All bound methods are async from the frontend's perspective. Errors from Go are thrown as JavaScript exceptions.

### Event Channels (Go → Frontend)

Go pushes events to the frontend using `application.EmitEvent(app, "event-name", data)` in v3 (or `runtime.EventsEmit(ctx, ...)` in v2 style). Frontend subscribes with `EventsOn`.

**Events emitted by Go:**

| Event Name | Payload | When Emitted |
|---|---|---|
| `queue-update` | `EmailWithId[]` — full current queue | New email arrives from watcher OR email deleted |
| `auth-changed` | `AuthStatus` | Token obtained, refreshed, or revoked |
| `draft-created` | `DraftResult` + email ID | Auto-draft mode draft created |
| `update-available` | `UpdateInfo` | Background update check finds new version |
| `error` | `{message: string}` | Unrecoverable error needing user attention |

**Frontend subscribes:**

```typescript
import { EventsOn } from '../wailsjs/runtime/runtime';

EventsOn('queue-update', (queue: EmailWithId[]) => {
    setEmails(queue);
});
```

### Queue-Update Emission Pattern

The watcher's callback mechanism must change: instead of calling `messaging.SendEmail()` on a `NativeMessaging` stdin/stdout writer, it calls a callback registered by the App struct, which then emits the event:

```go
// watcher.go — change the callback type
type WatcherCallback func(emails map[string]*MailMessage)

// EmailWatcher carries an onUpdate callback instead of *NativeMessaging
type EmailWatcher struct {
    onUpdate WatcherCallback
    // ... rest unchanged
}

// app.go — App registers its own callback
func (a *App) onWatcherUpdate(emails map[string]*MailMessage) {
    queue := toEmailWithIdSlice(emails)
    application.EmitEvent(a.ctx, "queue-update", queue)
    a.updateTrayBadge(len(queue))
}
```

This is the key structural change to `watcher.go`: replace the `*NativeMessaging` dependency with a `WatcherCallback` function. All other watcher logic (debouncing, AV retry, validation, ID generation) is preserved unchanged.

---

## 4. Watcher Lifecycle

### Where It Lives

The `EmailWatcher` is created during `OnStartup` and stopped during `OnShutdown`. These are Wails application lifecycle hooks.

```go
// main.go
app := application.New(application.Options{
    OnStartup: func(ctx context.Context) {
        a.ctx = ctx
        a.watcher, _ = NewEmailWatcher(watchDir, a.onWatcherUpdate)
        a.watcher.Start()
        a.auth.LoadToken()
        go a.runAutoModeLoop()
    },
    OnShutdown: func(ctx context.Context) {
        a.watcher.Stop()
    },
})
```

### When the Window is Hidden (Minimized to Tray)

In Wails v3, when the window is hidden (`window.Hide()`), the Go process continues running. The watcher goroutine keeps running. Events can still be emitted — they queue up and deliver when the frontend reconnects on window show.

This is the correct behavior for go-mapi: the DLL can keep writing files, the watcher keeps processing them, and when the user opens the window they see the current queue without delay.

### Window Lifecycle

```go
window := app.NewWebviewWindowWithOptions(application.WebviewWindowOptions{
    Hidden:          true,   // start hidden
    HiddenOnTaskbar: true,   // no taskbar button when hidden
    AlwaysOnTop:     false,
    Width:           440,
    Height:          600,
})

// Intercept close: hide instead of quit
window.OnWindowEvent(events.Common.WindowClosing, func(event *application.WindowEvent) {
    event.Cancel()
    window.Hide()
})
```

### Auto-Mode Loop

When mode is `auto-draft` or `auto-send`, Go processes emails automatically without window interaction. The auto-mode loop runs as a goroutine started in `OnStartup`:

```go
func (a *App) runAutoModeLoop() {
    for email := range a.watcher.NewEmailChan() {
        settings := a.GetSettings()
        switch settings.Mode {
        case "auto-draft":
            a.CreateDraft(email.ID)
        case "auto-send":
            a.SendEmail(email.ID)
        }
    }
}
```

This requires adding a `NewEmailChan()` channel to `EmailWatcher` alongside the callback, or merging the two patterns. The callback is used for UI events; the channel is used for auto-mode processing.

---

## 5. OAuth Token Storage and Refresh

### Flow

Replace `chrome.identity.getAuthToken()` with the Google Desktop App OAuth2 loopback flow:

1. App opens user's default browser to `https://accounts.google.com/o/oauth2/auth?redirect_uri=http://127.0.0.1:{port}&...`
2. App starts local HTTP server on a random high port (e.g., `:0` bound)
3. Google redirects to `http://127.0.0.1:{port}/?code=...`
4. App exchanges code for access + refresh tokens via `https://oauth2.googleapis.com/token`
5. Tokens stored in OS credential vault

**Reference:** https://developers.google.com/identity/protocols/oauth2/native-app — loopback redirect continues to be supported for desktop apps (not deprecated).

### Token Storage

Use `github.com/99designs/keyring` — the standard Go cross-platform credential vault library. On Windows it uses Windows Credential Manager (WinCredBackend). This satisfies the "OS credential vault, not disk" requirement.

```go
// auth.go
import "github.com/99designs/keyring"

const keyringService = "go-mapi"
const keyringKey = "oauth-tokens"

type AuthManager struct {
    ring   keyring.Keyring
    tokens *OAuthTokens
    mu     sync.RWMutex
}

type OAuthTokens struct {
    AccessToken  string    `json:"access_token"`
    RefreshToken string    `json:"refresh_token"`
    Expiry       time.Time `json:"expiry"`
}
```

### Token Refresh Strategy

The access token is short-lived (~1 hour). Refresh happens transparently:

1. Before each Gmail API call, check `tokens.Expiry.Before(time.Now().Add(5 * time.Minute))`
2. If expiring, call `https://oauth2.googleapis.com/token` with `grant_type=refresh_token`
3. Store updated tokens back to keyring
4. If refresh fails (revoked token), clear keyring, emit `auth-changed` with `{authenticated: false}`, prompt user to sign in again

The existing `GmailClient` handles 401 returns as `"token expired"` errors. In v3, the App struct catches these, triggers refresh, and retries. The `GmailClient` itself stays stateless (receives token per call — unchanged from v2 architecture).

### GCP Application Type

The existing GCP OAuth app registered for the browser extension uses `chrome_extension` type. A new OAuth 2.0 client of type **Desktop app** must be created in the same GCP project. Desktop apps do not require a verified redirect URI — the loopback `http://127.0.0.1` is inherently trusted. The `client_id` and `client_secret` are embedded in the Go binary (acceptable for FOSS desktop apps; Google's own guidance accepts this).

---

## 6. Tray vs Window Split

### Process Model

The Wails app is a single process. There is no separate tray process. The tray IS the persistent process. The window is created once at startup (hidden) and shown/hidden on demand.

```go
// main.go
systemTray := app.NewSystemTray()
systemTray.SetIcon(trayIcon)   // embedded ICO resource
systemTray.SetTooltip("go-mapi")

// Left-click: toggle window
systemTray.OnClick(func() {
    if window.IsVisible() {
        window.Hide()
    } else {
        window.Show()
        window.Focus()
    }
})

// Right-click: context menu
menu := app.NewMenu()
menu.Add("Open").OnClick(func(_ *application.Context) { window.Show() })
menu.Add("Sign Out").OnClick(func(_ *application.Context) { a.SignOut() })
menu.AddSeparator()
menu.Add("Quit").OnClick(func(_ *application.Context) { app.Quit() })
systemTray.SetMenu(menu)
```

### Tray Badge (Queue Count)

The tray icon does not have a native badge API on Windows. The pattern is to re-render the tray icon with a count overlay. Use `image` + `draw` stdlib packages to composite the count onto the base icon at runtime.

```go
func (a *App) updateTrayBadge(count int) {
    if count == 0 {
        a.tray.SetIcon(baseIcon)
        a.tray.SetTooltip("go-mapi — no pending emails")
        return
    }
    icon := renderBadgedIcon(baseIcon, count)
    a.tray.SetIcon(icon)
    a.tray.SetTooltip(fmt.Sprintf("go-mapi — %d pending email(s)", count))
}
```

### Raise-Existing-Window

Use Wails v3's `single_instance` plugin (`github.com/wailsapp/wails/v3/plugins/single_instance`). When a second instance is launched (e.g., user double-clicks the exe), the plugin sends a signal to the running instance which can respond by showing the window.

```go
app.Use(single_instance.New(single_instance.Options{
    UniqueID: "com.gomapi.app",
    OnSecondInstanceLaunch: func(secondInstanceData single_instance.SecondInstanceData) {
        window.Show()
        window.Focus()
    },
}))
```

### State Location

All application state lives in the Go process (in-memory + keyring + `%APPDATA%\go-mapi\settings.json`). The window/frontend holds no persistent state — it reads from Go on mount and reacts to events.

```
Go process (persistent):
  - Email queue (EmailWatcher in-memory map)
  - OAuth tokens (keyring)
  - Settings (AppSettings in %APPDATA%\go-mapi\settings.json)
  - Update check result (in-memory, checked on startup)

Frontend (ephemeral, per-window-open):
  - Displayed queue (local React state, refreshed from Go via GetQueue + events)
  - Selected email detail (local UI state)
  - Auth status (refreshed from Go via GetAuthStatus)
```

---

## 7. Autoupdate Architecture

### Approach: In-App Update Check + Notify Only (No Silent Replace)

Wails v3 does not have built-in autoupdate. Wails v2 GitHub Issue #1178 was never resolved. The recommended pattern for Go desktop apps is `github.com/creativeprojects/go-selfupdate`.

**However:** On Windows, replacing a running executable requires the old process to exit first. Silent in-place replacement is complex and can corrupt if the update crashes mid-write. For v3.0, implement **update notification only** — check for a new version, show a notification, let the user download and run the new installer manually. This is the pragmatic choice for a solo maintainer FOSS project.

**Full self-replace can be deferred to a later milestone.**

### Update Check Flow

```go
// updater.go
func (a *App) CheckForUpdate() (*UpdateInfo, error) {
    updater, err := selfupdate.NewUpdater(selfupdate.Config{
        Source: selfupdate.NewGitHubSource(selfupdate.GitHubConfig{
            OwnerName:      "marcfargas",
            RepositoryName: "go-mapi",
        }),
    })
    if err != nil {
        return &UpdateInfo{Available: false}, nil
    }
    latest, found, err := updater.DetectLatest(context.Background(), selfupdate.NewRepositorySlug("marcfargas", "go-mapi"))
    if err != nil || !found {
        return &UpdateInfo{Available: false}, nil
    }
    current := semver.MustParse(Version)
    if latest.Version.GT(current) {
        return &UpdateInfo{Available: true, Version: latest.Version.String(), URL: latest.ReleaseURL}, nil
    }
    return &UpdateInfo{Available: false}, nil
}
```

### Cadence

Check on app startup (once, non-blocking goroutine). If update available, emit `update-available` event to frontend, show a tray notification, update tray tooltip.

### Opt-Out

The `AppSettings.UpdatesEnabled` field controls whether the check runs. Default: true. Persisted in `%APPDATA%\go-mapi\settings.json`.

### No Separate Updater Process

No separate updater binary or scheduled task. The check is a lightweight HTTP call to the GitHub API at startup. This avoids all the complexity of background services, scheduled tasks, and binary-replacement races.

---

## 8. Installer Changes

### What the v3 Installer Installs

| Component | Action | Notes |
|---|---|---|
| `go-mapi.exe` (Wails app) | Install to `%ProgramFiles%\go-mapi\` | Replaces `go-mapi-host.exe` |
| `go-mapi.dll` (MAPI interceptor) | Install to `%System32%\` (32-bit) and `%ProgramFiles%\go-mapi\` (64-bit) | UNCHANGED |
| Registry MAPI handler | Write `HKLM\SOFTWARE\Clients\Mail\go-mapi` | UNCHANGED |
| `%TEMP%\go-mapi\` directory | Create on first run (app creates it) | No installer action needed |
| WebView2 Runtime | Check; bootstrap install if missing | See below |
| Run at startup | Add `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\go-mapi` | NEW — tray app should autostart |

### WebView2 Runtime Bootstrap

WebView2 is NOT bundled. Use the Microsoft Evergreen Bootstrapper:

```pascal
// In Inno Setup [Code] section — PrepareToInstall()
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  if not RegKeyExists(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}') then
  begin
    // Download and run MicrosoftEdgeWebview2Setup.exe /silent /install
    DownloadBootstrapper();
    RunBootstrapper();
  end;
  Result := '';
end;
```

Machine-wide installation (`/install` flag, not `/installlevel`) is required for RDS environments so all user sessions share the runtime.

### Autostartup Entry

The tray app must persist after logout/login. Register in `HKCU\Run` (user-level, no admin required after install):

```pascal
[Registry]
Root: HKCU; Subkey: "SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: string; ValueName: "go-mapi"; \
  ValueData: """{app}\go-mapi.exe"""; Flags: uninsdeletevalue
```

### What the Installer No Longer Does

- Does NOT install native messaging manifests (`com.gomapi.host.json`) to `%APPDATA%\Google\Chrome\...` or `%APPDATA%\Microsoft\Edge\...`
- Does NOT set `allowed_origins` registry keys for Chrome/Edge native messaging
- Does NOT require Chrome or Edge to be installed

---

## 9. Migration Cleanup — v2.x Artifact Detection and Removal

### v2.x Artifacts to Remove

| Artifact | Location | Detection Method |
|---|---|---|
| Native host binary | `%ProgramFiles%\go-mapi\go-mapi-host.exe` | File exists check |
| Chrome native messaging manifest | `%APPDATA%\Google\Chrome\NativeMessagingHosts\com.gomapi.host.json` | File exists check |
| Edge native messaging manifest | `%APPDATA%\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host.json` | File exists check |
| HKCU Chrome NM registry | `HKCU\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host` | RegKeyExists |
| HKLM Chrome NM registry | `HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host` | RegKeyExists |
| v2 uninstall entry | `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi_is1` | RegKeyExists |
| Old `%APPDATA%\go-mapi\` config dir | If v2 wrote anything here | Directory exists check |

### Cleanup Strategy in v3 Installer

Inno Setup `[Code]` section `InitializeSetup()`:

```pascal
function InitializeSetup(): Boolean;
var
  UninstallStr: String;
begin
  // Detect v2.x installation and run its uninstaller first
  if RegQueryStringValue(HKLM,
    'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi_is1',
    'UninstallString', UninstallStr) then
  begin
    if MsgBox('go-mapi v2.x is installed. Remove it before installing v3?',
              mbConfirmation, MB_YESNO) = IDYES then
    begin
      Exec(RemoveQuotes(UninstallStr), '/SILENT', '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
    end;
  end;
  Result := True;
end;
```

Additionally, use `[InstallDelete]` to remove native messaging manifests if they survive the v2 uninstaller:

```pascal
[InstallDelete]
Type: files; Name: "{userappdata}\Google\Chrome\NativeMessagingHosts\com.gomapi.host.json"
Type: files; Name: "{userappdata}\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host.json"
```

### Clean Break, Not In-Place Upgrade

v3.0 is a clean-break migration. Users uninstall v2.x (via the prompt above or manually), then install v3.0. There is no in-place upgrade path. The Inno Setup `AppId` for v3.0 uses a new GUID to prevent Inno Setup from treating it as an upgrade of the same application.

---

## 10. Data Flow Diagrams

### Email Arrives → Queue Update → User Action → Gmail API

```
[Windows App] calls MAPISendMail()
    ↓
[go-mapi.dll] intercepts → writes {uuid}.json to %TEMP%\go-mapi\
    ↓
[fsnotify watcher] detects Create event (debounced 500ms)
    ↓
[EmailWatcher.processFile()] reads → validates → normalizes → generates ID
    ↓
[App.onWatcherUpdate()] callback fires
    ↓
[application.EmitEvent(ctx, "queue-update", queue)] — Go → WebView2
    ↓
[Frontend EventsOn("queue-update")] → React state update → re-render EmailList
    ↓ (also)
[App.updateTrayBadge(count)] → tray icon re-rendered with count badge
    ↓
User opens window (left-clicks tray) → sees updated list
    ↓
User clicks "Save as Draft" → Frontend calls CreateDraft(id)
    ↓
[App.CreateDraft(id)] → AuthManager.GetToken() → checks expiry → refresh if needed
    ↓
[GmailClient.CreateDraft(email)] → buildFullMIME(msg) → POST /gmail/v1/users/me/drafts
    ↓
Gmail API returns draft ID
    ↓
[App.CreateDraft] → watcher.MarkProcessed(id) → os.Remove(jsonFile)
    ↓
[onWatcherUpdate fires again] → "queue-update" event with email removed
    ↓
Frontend removes email from list, shows success toast
    ↓ (also)
[application.EmitEvent(ctx, "draft-created", result)] → optional additional event
```

### Auto-Draft Mode Flow

```
New email detected by watcher
    ↓
onWatcherUpdate callback fires
    ↓ (mode == "auto-draft")
App.runAutoModeLoop() picks up email from channel
    ↓
App.CreateDraft(id) — same path as manual, no window interaction
    ↓
On success: emit "queue-update" (now empty or reduced)
On error: emit "error" event → show tray notification
```

### Token Refresh Flow

```
App.CreateDraft(id) called
    ↓
AuthManager.GetToken()
    → token.Expiry > now + 5min? → return token (fast path)
    → else: POST /token with refresh_token
        → success: store new access + expiry in keyring, return token
        → 401 (token revoked): clear keyring, emit "auth-changed" {authenticated:false}
            → Frontend shows AuthPrompt, user clicks "Sign In"
            → Frontend calls App.SignIn()
            → OAuth loopback flow → new tokens stored
            → emit "auth-changed" {authenticated:true}
            → user retries draft creation
```

---

## 11. Build Order / Dependency Graph

The phases of v3 development have hard dependencies. Build this order:

```
Phase 1: Wails Shell + Tray (no functionality)
    - Scaffold Wails v3 app at src/app/
    - System tray with show/hide window
    - Single-instance enforcement
    - App compiles and runs; window shows placeholder UI
    GATE: app.exe runs, tray appears, window shows/hides

Phase 2: Watcher Integration
    - Move watcher.go, gmail.go, protocol.go (types only) into src/app/
    - Replace NativeMessaging dep with WatcherCallback
    - Wire onWatcherUpdate → EmitEvent("queue-update")
    - GetQueue() bound method
    GATE: emails arriving in %TEMP%\go-mapi appear in console/event log

Phase 3: Frontend Queue Viewer
    - React frontend: EmailList + EmailDetail (port from extension)
    - Subscribe to "queue-update" events
    - Call GetQueue() on mount
    - DeleteEmail() action
    GATE: queue visible in window; delete works; no OAuth yet

Phase 4: OAuth + Gmail Integration
    - auth.go with loopback flow + keyring storage
    - CreateDraft() + SendEmail() bound methods
    - AuthStatus + SignIn/SignOut
    - AuthPrompt component in frontend
    GATE: full draft creation end-to-end; token survives restart

Phase 5: Mode Toggle + Auto-Mode
    - AppSettings (manual/auto-draft/auto-send)
    - Settings persistence to %APPDATA%\go-mapi\settings.json
    - runAutoModeLoop() goroutine
    - Settings UI in frontend
    GATE: auto-draft mode processes emails without window open

Phase 6: Installer + Migration
    - Updated Inno Setup .iss (Wails binary, WebView2 bootstrap, autostart, cleanup)
    - v2.x artifact detection and removal
    - Uninstaller parity
    GATE: clean install on fresh Windows 10/11; v2.x upgrade path tested

Phase 7: Autoupdate + Polish
    - updater.go with go-selfupdate check
    - Tray badge (queue count overlay on icon)
    - Tray notifications for new emails
    - Update notification in tray/window
    GATE: end-to-end user flow from fresh install to draft creation
```

**Why this order:**
- Phase 1 before everything: Wails v3 alpha may have project-setup surprises; fail fast
- Phase 2 before Phase 3: Frontend is useless without data; backend must work first
- Phase 3 before Phase 4: Separate concerns; queue viewer testable without auth
- Phase 4 after Phase 3: OAuth is the highest-complexity new piece; keep isolated
- Phase 5 after Phase 4: Auto-mode requires working draft creation
- Phase 6 late: Installer is the distribution concern; core functionality comes first
- Phase 7 last: Polish and update check are non-blocking to core value

---

## 12. Anti-Patterns to Avoid

### Anti-Pattern 1: Keeping NativeMessaging as the Watcher Callback Interface

**What:** Leaving `EmailWatcher` typed to `*NativeMessaging` and wrapping it in a fake NativeMessaging that emits Wails events.
**Why bad:** NativeMessaging is a stdin/stdout 4-byte-framed protocol — it's meaningless in a non-native-messaging context. Creates dead code and confusion.
**Do this instead:** Replace `*NativeMessaging` in EmailWatcher with `func(map[string]*MailMessage)` callback. One-line change in `NewEmailWatcher()` signature; the rest of watcher.go is untouched.

### Anti-Pattern 2: Running Wails Frontend State as Source of Truth

**What:** Storing the email queue in React state only; not re-syncing from Go on window open.
**Why bad:** The window can be hidden and re-shown; the frontend context may be stale or the service worker equivalent doesn't exist in Wails. Events missed while hidden don't auto-replay.
**Do this instead:** On every window show event, call `GetQueue()` to refresh full state. Use events only as an incremental update signal. The queue source of truth is always the Go in-memory map (not the frontend).

### Anti-Pattern 3: Embedding WebView2 Runtime

**What:** Using Wails' bundled WebView2 (fixed version embedded in binary) instead of Evergreen runtime.
**Why bad:** Wails binary size explodes. More critically, on RDS each user session runs a separate WebView2 process if not using the shared Evergreen runtime — multiplying RAM usage. Embedded WebView2 cannot share the Edge renderer across sessions.
**Do this instead:** Use Evergreen (machine-wide) runtime. Check at install time; bootstrap if missing. Accept the online dependency; WebView2 is present on all modern Windows 10/11 machines (ships with Windows Update since 2021).

### Anti-Pattern 4: Storing OAuth Tokens in a File

**What:** Writing `tokens.json` to `%APPDATA%\go-mapi\` with the access and refresh token.
**Why bad:** Any process running as the same user can read `%APPDATA%`. Refresh tokens are effectively permanent credentials.
**Do this instead:** Use Windows Credential Manager via `github.com/99designs/keyring`. The token is encrypted at rest by the OS, tied to the user's login. The file-based approach is only acceptable for non-sensitive settings (AppSettings).

### Anti-Pattern 5: Using Wails v2 for This Project

**What:** Building on Wails v2 because it's stable, using go-systray or a third-party tray library.
**Why bad:** The Wails team confirmed v2 won't get systray support. Third-party tray integration with Wails v2 has known Objective-C linking conflicts on macOS (not relevant here, but signals fragility). The workaround would require `go:build` hacks and Win32 API calls outside the Wails lifecycle. More maintenance burden than accepting Wails v3 alpha.
**Do this instead:** Use Wails v3. Pin to a specific alpha tag (e.g., `v3.0.0-alpha.74`). Update alpha version only intentionally, not automatically.

### Anti-Pattern 6: Checking for Updates on Every App Event

**What:** Polling GitHub releases API on watcher events or frequent intervals.
**Why bad:** GitHub API has rate limits (60 unauthenticated requests/hour). Users on RDS may share an IP, multiplying requests across sessions.
**Do this instead:** Check once at startup, and once per day via a `time.Ticker` that fires only if the app has been running more than 24 hours. Cache the last check time in settings.

---

## 13. Integration Points Summary

| New Component | Integrates With | Integration Mechanism | Status |
|---|---|---|---|
| Wails App (`src/app/`) | `src/interceptor/` (DLL) | Filesystem IPC unchanged (`%TEMP%\go-mapi\`) | No change needed |
| `watcher.go` (moved) | Wails App | WatcherCallback replaces NativeMessaging | Single function signature change |
| `gmail.go` (moved) | Wails App | Called by App.CreateDraft / App.SendEmail | No changes to gmail.go internals |
| `auth.go` (new) | `github.com/99designs/keyring` | Windows Credential Manager | New dependency |
| `auth.go` (new) | Google OAuth2 endpoints | HTTP loopback redirect + token exchange | New code |
| `updater.go` (new) | `github.com/creativeprojects/go-selfupdate` | GitHub Releases API | New dependency |
| Inno Setup `.iss` | WebView2 Evergreen Bootstrapper | Microsoft download + silent install | Installer code change |
| Inno Setup `.iss` | v2.x uninstaller | RegQueryStringValue → Exec uninstall | New cleanup code |
| Frontend | `wailsjs/go/main/App.*` (generated) | Wails TypeScript bindings | Auto-generated |
| Frontend | `wailsjs/runtime/runtime.ts` (generated) | EventsOn / EventsEmit | Auto-generated |

---

## Sources

- Wails v3 systray support confirmation (v2 won't get it): https://github.com/wailsapp/wails/discussions/4514
- Wails v3 systray-basic example (alpha.74): https://pkg.go.dev/github.com/wailsapp/wails/v3/examples/systray-basic
- Wails v3 systray-menu example: https://pkg.go.dev/github.com/wailsapp/wails/v3/examples/systray-menu
- Wails v3 single_instance plugin: https://pkg.go.dev/github.com/wailsapp/wails/v3/plugins/single_instance
- Wails v2 App options (StartHidden, HideWindowOnClose): https://pkg.go.dev/github.com/wailsapp/wails/v2@v2.11.0/pkg/options
- Wails v3 bindings/events changes from v2: https://v3alpha.wails.io/migration/v2-to-v3/
- Google OAuth2 loopback redirect for desktop apps: https://developers.google.com/identity/protocols/oauth2/native-app
- Google loopback migration guide (confirms desktop loopback stays supported): https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration
- keyring library (Windows Credential Manager): https://github.com/99designs/keyring
- go-selfupdate (GitHub Releases based): https://github.com/creativeprojects/go-selfupdate
- WebView2 RDS/per-machine install guidance: https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution
- WebView2 machine-wide install requirement for RDS: https://github.com/MicrosoftEdge/WebView2Feedback/issues/3338
- Inno Setup WebView2 registry detection: https://groups.google.com/g/innosetup/c/_SfytB8FGdI
- Inno Setup previous version uninstall pattern: https://www.w3tutorials.net/blog/how-to-automatically-uninstall-previous-installed-version-in-inno-setup/

---
*Architecture research for: go-mapi v3.0 Wails Pivot*
*Researched: 2026-04-12*
