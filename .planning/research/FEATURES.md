# Feature Research

**Domain:** Windows desktop tray app — MAPI-to-Gmail bridge (Wails + Go + WebView2)
**Milestone:** v3.0 Wails Pivot
**Researched:** 2026-04-12
**Confidence:** HIGH (Windows conventions verified against official Microsoft docs; OAuth from Google official docs; Wails from GitHub issues/discussions)

Scope: NEW behaviors introduced in v3.0 that did not exist in the v2.x extension. Existing features
(queue viewer, draft creation, filesystem IPC, MIME building) are preserved and not re-researched here.
Privacy baseline (no telemetry, no content retention, no network calls outside Gmail API) applies to
every feature — honored explicitly in each recommendation.

---

## Feature Landscape

### 1. System Tray

#### Table Stakes

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Persistent tray icon at all times app is running | Every Windows background app (Slack, Teams, OneDrive, Dropbox) lives in the tray while running. Users expect this pattern for email-related daemons. | LOW | Wails v2 `systray` package supports icon + menu. Wails v3-alpha exposes same via `wails3 systray`. |
| Right-click context menu with at minimum: Show Window, Quit | The canonical tray right-click menu. Missing Quit means users can only kill from Task Manager. | LOW | Menu items: "Open go-mapi", separator, "Quit". Standard order per Windows conventions. |
| Icon tooltip on hover showing app name and queue status | Slack shows "Slack — N notifications". OneDrive shows sync state. Non-technical users look at tooltip to understand what an unknown tray icon does. | LOW | Max 127 chars on Win32; use "go-mapi — N email(s) pending" or "go-mapi — idle". |
| Single-click OR double-click to open main window | Windows has no universal standard here (MS guidelines say double-click; many apps use single-click). The practical convention now leans toward single-click for notification-area icons. | LOW | Implement left-click = show/toggle window. Right-click = context menu. This matches OneDrive, Teams, most modern apps. |
| Minimize-to-tray when user closes window (X button) | Users of background apps expect closing the window does NOT quit the app. Quitting from tray menu or explicit Quit item is the intended exit path. | LOW | Intercept `WM_CLOSE` / Wails `OnBeforeClose` callback; hide window instead of destroying. |
| Visual indication that app is connected and watching | If the tray icon is blank/static when the queue watcher fails, users don't know something is wrong. | MEDIUM | At minimum: two icon states — normal (watching), error (watcher failed / OAuth missing). |

#### Differentiators

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Queue-count badge on tray icon | Shows unprocessed email count directly on the icon (e.g. "3" overlaid). OneDrive does this for sync errors; Teams does it for unread. Means users never need to open the window to check. | MEDIUM | Windows Shell_NotifyIcon with NIIF_USER allows badge rendering. Requires generating icon variants at runtime (Go `image` package overlaying count text) or a set of pre-rendered icons for 0/1/2/3/5/10+. |
| Separate icon states: idle / active (processing) / queued / error | Four distinct visual states. Idle = no pending emails. Active = currently creating a draft. Queued = N emails waiting. Error = OAuth expired or watcher failed. | MEDIUM | Four icon assets (16x16 SVG/PNG). Go renders correct icon from tray package on state change. |
| "Pause automode" in context menu | Power users want to temporarily disable auto-processing without opening the window. One-click toggle in the context menu. | LOW | Context menu item with checkmark state. Writes preference to config. No modal window needed. |
| Show/hide window toggle from context menu | "Open go-mapi" changes to "Hide go-mapi" when window is visible. Feels polished, matches Slack behavior. | LOW | Query window visibility state before rendering menu. |

#### Anti-Features

| Feature | Why Avoid | What to Do Instead |
|---------|-----------|-------------------|
| Admin prompt on every right-click open | Some old tray apps relaunch elevated on menu actions. Unacceptable UX and a security flag. | All actions run in the existing process. Admin is only needed at install time (registry). |
| "Start with Windows" toggle that silently modifies HKCU Run key without user awareness | Seems convenient; actually surprises users who don't expect it. | Do not add autostart during install. Provide an explicit toggle in Settings with clear text: "Launch go-mapi when Windows starts". |
| Balloon notifications from the tray icon itself (legacy) | The old `NIIF_INFO` balloon is Windows 7-era and bypasses Action Center. Looks outdated on Windows 10/11. | Use WinRT toast notifications (Action Center integrated). |
| Blinking or animated tray icon on every email arrival | Photosensitivity concern; gets annoying immediately for high-volume users. | Static icon state change + single toast notification. |

---

### 2. Toast Notifications

#### Table Stakes

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Toast notification when a new email arrives in queue | Every Windows email client (new Mail app, Outlook) shows a toast. Non-technical users expect the OS to tell them something happened. | MEDIUM | WinRT `Windows.UI.Notifications.ToastNotification` API from Go via `go-toast` or `toast` package, or via Wails JS runtime calling into Go. For unpackaged Win32 apps, requires registering an AppUserModelID in the registry. |
| Notification content: sender name, subject line, attachment indicator | Matches Outlook and Gmail desktop notifications. Users need enough context to decide if they care. | LOW | Toast XML: title = sender display name, body line 1 = subject, body line 2 = "With attachments" (if any). No body text preview — privacy (content stays local). |
| Click notification to open app and show email detail | Standard click-through behavior. Clicking a Gmail toast opens Gmail to that message. Users expect this. | MEDIUM | Toast activation handler must route to the specific email's detail view. Requires passing email ID in the toast activation args. Wails handles window focus; Go routes to the correct view. |
| Notification persists in Action Center after dismissal | Windows 10+ automatically puts dismissed toasts into Action Center. No developer action required — but the notification must use the correct app registration or it disappears. | LOW | Unpackaged Win32 apps must register an AppUserModelID and a COM activator (or use a shortcut in Start menu) for persistent Action Center presence. Without this, toast disappears immediately. |
| Clear notification from Action Center when email is processed | Email processed (draft created / deleted) → notification becomes stale. Microsoft's own guidance: clear stale notifications so users don't feel they missed something. | MEDIUM | On draft creation or email deletion, call `ToastNotificationManager.History.Remove(tag, group)` using the email's ID as the tag. |

#### Differentiators

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| "Draft now" action button on toast | Users can trigger draft creation without opening the app. Outlook's "Quick Reply" pattern — reduces friction to zero for the common case. | MEDIUM | Toast action button: label "Create Draft", activationType="background". Wails background activation handler calls `GmailClient.CreateDraft()`. Max 5 buttons per toast. |
| "Dismiss" action button on toast (removes from queue) | Allows discarding an email (user triggered the wrong "Send Mail" action) without opening the app. | LOW | Second toast action button. Background activation calls `EmailWatcher.Delete()`. Pair with notification removal. |
| Notification grouping under a "go-mapi" header when multiple emails queue up | If 3 emails arrive in quick succession, group them under one header in Action Center rather than 3 separate toast banners. Matches how Windows Mail groups messages. | MEDIUM | Use `ToastNotificationManager` `tag` (per-email ID) + `group` ("go-mapi-queue"). Windows automatically collapses grouped notifications in Action Center. Banner still fires per email, but AC is tidy. |
| Suppressed (silent) notification in Focus/Do Not Disturb mode | Windows 11 Focus Sessions suppress standard banners. Showing a banner during a focus session is rude; silently adding to AC is fine. | LOW | Detect `FocusSessionManager.IsFocusActive` (WinRT API). If true, send notification with `SuppressPopup = true` — goes straight to Action Center without a banner. |

#### Anti-Features

| Feature | Why Avoid | What to Do Instead |
|---------|-----------|-------------------|
| Showing email body text in notification | Body text preview exposes PII in a transient OS UI element that persists in Action Center. Violates privacy model. | Show sender + subject only. Never body text. |
| Notification per attachment (multiple toasts for one email) | Spammy. Users will turn off notifications immediately. | One toast per email regardless of attachment count. Show "2 attachments" in the body line. |
| Persistent "reminder" toasts that re-fire every N minutes | Annoying. Windows has no enforcement mechanism preventing re-fire but users hate it. | One toast per email arrival. Badge count on tray icon is the persistent reminder. |
| Using old-style `Shell_NotifyIcon` balloon tooltips (NIIF_INFO) | Bypasses Action Center; looks like Windows 7. | Use WinRT toast API. |
| Requiring app to be open for notifications to work | Background apps must send notifications even when UI window is closed. | Wails app runs continuously in the tray; Go watcher goroutine fires toasts regardless of window state. |

---

### 3. Automode (Auto-draft / Auto-send / Manual)

#### Table Stakes

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Global mode toggle: Manual / Auto-draft / Auto-send | The core v3.0 feature. Users expect a clear, named setting — not a hidden config file. Manual = queue only; Auto-draft = create Gmail draft automatically; Auto-send = send immediately. | MEDIUM | Setting stored in user config file (not registry — no admin needed). Persisted across restarts. Default: Manual. |
| Mode visible in tray icon tooltip and/or context menu | Users need to know the current mode without opening the window. "go-mapi — Auto-draft — 0 pending" in tooltip is clear. | LOW | Update tooltip string on mode change. Optionally add a read-only mode indicator in context menu. |
| Visual confirmation after auto-action | When auto-draft creates a draft, the user should know it happened (brief notification or badge update). Silent success feels like a bug to non-technical users. | LOW | Toast notification: "Draft created: [subject]" with "Open in Gmail" button (optional, if Gmail URL is constructable). |
| Error handling: fallback to manual queue if auto-action fails | Auto-draft fails (OAuth expired, network error) → email stays in manual queue + error notification. Discarding the email silently is unacceptable. | MEDIUM | On auto-action failure: keep email in watcher's pending set, update icon to error state, fire error toast with "Sign in required" or "Network error — email queued". |
| Per-session mode persistence (survives restart) | Setting a mode should not reset on every app restart. | LOW | Write mode to config file on change. Read on startup. |

#### Differentiators

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Mode toggle accessible from both tray context menu and main window | Power users prefer tray menu; new users prefer the visible UI. Both are valid. | LOW | Context menu: radio items (Manual ✓ / Auto-draft / Auto-send). Main window: segmented control or radio group. Both write to the same config. |
| "Undo" window — brief delay before auto-action with cancel option | For Auto-send specifically: give the user 5-10 seconds to cancel before the email is sent. Matches Gmail's "undo send" behavior. Especially important because sending (not drafting) is irreversible. | MEDIUM | On auto-send trigger: show a transient "Sending in 5s... [Cancel]" banner in-window or as a progress-bar toast. If cancelled, keep in queue. If confirmed (timeout), proceed. For Auto-draft, undo is less critical (drafts are reversible). |
| Different icon state per mode | Idle-manual vs idle-auto-draft vs idle-auto-send icon variants. Polished apps (e.g., Little Snitch) use distinct icon styles per operational mode. | MEDIUM | Three additional icon assets. Low implementation cost after icon states are introduced for queue/error. |

#### Anti-Features

| Feature | Why Avoid | What to Do Instead |
|---------|-----------|-------------------|
| Auto-send without any confirmation or delay | Irreversible. One misfire (wrong MAPI call, mis-addressed email from legacy app) sends an email that can't be recalled. | Always show undo window for Auto-send mode. Default mode is Manual. |
| Per-email mode override (each email has its own mode setting) | Sounds flexible; in practice, non-technical users are confused by per-item state. Queue becomes hard to reason about. | Global mode only for v3.0. Per-email override is a v4+ feature if user research demands it. |
| Automode that requires the window to be open | Automode is only valuable when the user is not watching. | Automode logic runs in the Go background goroutine, not in the WebView/UI layer. Window state irrelevant. |
| Automatic retry of failed auto-actions without user awareness | Silent retries on OAuth failure will loop forever or generate duplicate drafts. | On first failure: fallback to queue + notify user. Do not retry automatically. |

---

### 4. Desktop OAuth Flow

#### Table Stakes

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Opens system browser for consent (not an embedded webview) | Google's official OAuth guidance explicitly forbids embedded webviews for the consent screen. Users expect to see their browser for any login flow. RFC 8252 mandates this. | MEDIUM | `exec.Command("rundll32", "url.dll,FileProtocolHandler", authURL)` on Windows, or `ShellExecuteW`. Do NOT use Wails WebView2 as the OAuth browser. |
| Loopback redirect (127.0.0.1 on ephemeral port) | Standard for native desktop apps per RFC 8252 and Google's desktop OAuth docs. Ephemeral port (>1024) avoids admin UAC prompt for binding. | MEDIUM | Go `net/http` listener on `127.0.0.1:0` (OS-assigned port). Redirect URI registered in GCP as `http://127.0.0.1` (no port — Google allows any port for loopback). |
| PKCE (S256 method) | Google requires PKCE for native app flows. Without it, the OAuth request is rejected. | LOW | Generate cryptographically random 43-128 char verifier; SHA256 hash as challenge (base64url, no padding). Standard in any modern OAuth library. |
| "Waiting for authorization..." UX during browser redirect | Between opening the browser and receiving the callback, the user needs to know the app is waiting. Blank window or frozen UI feels broken. | LOW | Show an in-window status: "A browser window has been opened for sign-in. Return here after authorizing." with a Cancel button. |
| Secure token storage in OS credential vault | Storing the refresh token in a plain text config file is unacceptable. Windows Credential Manager (DPAPI-backed) is the right location. | MEDIUM | `zalando/go-keyring` provides a clean Go API for Windows Credential Manager. Key: "go-mapi/gmail-refresh-token", value: refresh token. No token ever written to disk in plaintext. |
| Token refresh without user interaction | Access tokens expire in 1 hour. Refresh token flow must work silently in the background. | MEDIUM | Before each Gmail API call: check token expiry. If <5 min remaining, exchange refresh token for new access token via `https://oauth2.googleapis.com/token`. Handle refresh failure (revoked grant) by prompting sign-in again. |

#### Differentiators

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| "Signed in as [email]" shown in main window and tray tooltip | Users want to know which Gmail account is active. Slack shows workspace name. | LOW | After OAuth, call `https://www.googleapis.com/oauth2/v3/userinfo` with access token. Cache display name + email address in memory (not on disk). Show in UI header. |
| "Sign out" option in Settings | Complete the auth lifecycle. Users who revoke in Google account settings should also be able to clean up locally. | LOW | Delete refresh token from Credential Manager. Clear in-memory state. Prompt re-auth on next auto-action attempt. |
| Graceful handling of externally revoked grant | User revokes go-mapi access in Google Account settings. Next API call returns 401. App must detect this specifically (not treat it as a transient network error) and prompt re-auth. | MEDIUM | HTTP 401 with `error: "invalid_grant"` in token refresh response → clear stored token → show "Authorization revoked — please sign in again" error notification. |
| Try IPv6 loopback (::1) if IPv4 (127.0.0.1) fails to bind | Google recommends attempting both. Some Windows configurations have unusual loopback stack behavior. | LOW | Try binding to 127.0.0.1; if error, try [::1]. Use whichever succeeds. Pass the actual bound address in the redirect_uri parameter. |

#### Anti-Features

| Feature | Why Avoid | What to Do Instead |
|---------|-----------|-------------------|
| Fixed loopback port (e.g. always 8080) | Port conflicts with other apps running on the same machine (common in dev environments). Requires firewall rule changes in some corporate configs. | Use OS-assigned ephemeral port (`:0`). |
| Storing refresh token in plaintext config file or registry string value | Plaintext credential in user-readable location violates privacy model. | Windows Credential Manager via `go-keyring`. DPAPI-backed, user-scoped. |
| Using an embedded WebView2 frame for the OAuth consent screen | Google's terms and RFC 8252 both prohibit this. The consent screen in an embedded webview cannot be trusted by the user (no address bar, no certificate indicator). | Always open the system default browser. |
| Caching user's email body or draft content in credential vault | Credential vault is for tokens only. Content must follow the existing delete-on-process model. | No content goes into Credential Manager. Refresh token only. |
| Polling for token validity on every watcher cycle (every 500ms) | Unnecessary network calls. Gmail does not require pre-flight token validation. | Check token expiry timestamp (in-memory) before each API call. Only refresh when needed. |

---

### 5. Autoupdate

#### Table Stakes

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Background update check on startup | Chrome, VS Code, Slack — every long-lived desktop app checks for updates on start. Non-technical users expect software to stay current without manual action. | MEDIUM | Go HTTP GET to a static JSON URL (e.g. GitHub Releases API or a hand-maintained `version.json` at a stable URL). Check is non-blocking; app starts normally regardless of outcome. |
| User notification when update is available (not forced) | OS-style convention: "A new version is available" toast or in-app banner. Forcing an update mid-session is hostile. | LOW | On update detected: show in-app banner in the main window header: "go-mapi v3.1.0 is available — [Download]". Optionally: a tray notification. |
| "Download update" opens the GitHub Release page or stable download URL in browser | Non-technical users get a familiar, trusted download experience. Avoids the complexity of in-process binary replacement on Windows (file locking issues). | LOW | Open `https://github.com/marcfargas/go-mapi/releases/latest` (or direct installer URL) in system browser. User downloads and runs the new installer manually. |
| Opt-out setting for update checks | Privacy-conscious users may not want any outbound network calls beyond Gmail API. Providing opt-out respects this. | LOW | Config key: `update_check_enabled: true` (default). UI toggle in Settings. When false: no HTTP calls to update endpoint at all. |
| Update check hits a static URL, not a dynamic tracking endpoint | Matches privacy model. A static `version.json` or the GitHub Releases API reveals no per-user data. | LOW | GitHub Releases API: `https://api.github.com/repos/marcfargas/go-mapi/releases/latest` returns `tag_name`. No auth required for public repos. No IP logging beyond what GitHub already does. |

#### Differentiators

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Show release notes in-app before download | VS Code shows a "What's New" page after update. Showing a brief changelog snippet in the update banner makes the value proposition clear ("this version fixes the attachment bug you hit"). | MEDIUM | Fetch `body` field from GitHub Releases API response. Display first N lines in an in-app modal or expandable banner. Cache for session to avoid repeated API calls. |
| Update check runs only once per day (not on every launch) | Avoids unnecessary network requests for users who launch and close the app frequently. | LOW | Store last-check timestamp in config file. Skip check if checked within 24 hours. |

#### Anti-Features

| Feature | Why Avoid | What to Do Instead |
|---------|-----------|-------------------|
| Silent in-process binary replacement (auto-apply update) | Windows file locking: a running `.exe` cannot be replaced. Squirrel/NSIS approaches work around this with rename tricks but require admin or a separate helper process. Adds significant complexity and potential for corrupted installs. | Download-and-run-installer pattern. Tell user "restart after running the installer". |
| Forced update / update gate (block app if not latest) | Hostile UX. FOSS tools should never gate functionality on a version requirement. | Inform, never block. |
| Telemetry to track which version each user is running | Violates privacy model. No per-user data ever leaves the machine. | Version check is a simple GET with no session IDs, no device fingerprinting. |
| Bundling auto-updater framework (Squirrel, WinSparkle) | Squirrel.Windows installs to user's `%LocalAppData%` and assumes a specific installer layout. Adds ~10 MB to the binary and significant integration complexity for a solo FOSS project. | Use `fynelabs/selfupdate` or `creativeprojects/go-selfupdate` (lightweight Go libraries) — or just the notify-and-open-browser pattern, which is zero-complexity and fully sufficient. |
| Checking for updates on every app action (watcher file event, etc.) | Wastes network on completely unrelated triggers. | Check only on startup, rate-limited to once per day. |

---

### 6. Installer UX

#### Table Stakes

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Single `.exe` installer (no zip extraction, no multi-step manual guide) | The v3.0 goal is non-technical users. Any installer that requires unzipping or reading a README fails the target user. | MEDIUM | NSIS installer (Wails has built-in NSIS support). Single file, double-click, done. |
| WebView2 runtime check + bootstrapper at install time | WebView2 is pre-installed on Windows 11 and most Win10 machines, but not all. Installer must detect absence and bootstrap silently. | MEDIUM | Check registry key `HKCU\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` (per-user) or `HKLM` equivalent. If absent, run `MicrosoftEdgeWebview2Setup.exe /silent /install` (bootstrapper bundled or downloaded). No admin needed for per-user WebView2 install. |
| SmartScreen warning guidance (pre-reputation) | Until SignPath builds reputation (~15K safe installs on Win 10/11 24H2+), Windows will show "Windows protected your PC" on first run. Non-technical users will panic and click "Don't Run". | LOW-MEDIUM | Include clear guidance on the download page and in the extension popup: "Windows may show a security warning — click 'More info' then 'Run anyway'." This is expected for new unsigned or low-reputation apps. SignPath OSS signing helps but does not eliminate SmartScreen until reputation builds. |
| Progress feedback during installation | A frozen installer with no progress bar looks like it crashed. | LOW | NSIS progress bar is default. Ensure each step (copy DLL, register, install WebView2) has a status line update. |
| Add/Remove Programs entry with version, publisher, uninstall path | Windows users expect to find any installed software in Settings > Apps or Control Panel > Programs. | LOW | NSIS `WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi"` with DisplayName, DisplayVersion, Publisher, UninstallString. |
| Clean uninstall: DLL, registry keys, MAPI handler, native host, manifests | Users who uninstall expect no leftover registry debris. IT administrators expect clean removal. | MEDIUM | Uninstall section must remove: MAPI handler registry (`HKLM\SOFTWARE\Clients\Mail\go-mapi`), native messaging manifests, DLL from install dir, app binaries, Add/Remove Programs entry. Optionally offer to delete `%TEMP%\go-mapi\` (with user confirmation — may contain unfailed email JSON). |
| "Already installed" detection and upgrade path | Running the installer on a machine with v2.x or earlier v3.x installed should not create duplicate entries. | MEDIUM | Check `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi`. If present, run existing uninstaller silently before proceeding with fresh install. |

#### Differentiators

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| "Temp files cleanup" prompt during uninstall | Non-technical users don't know `%TEMP%\go-mapi\` exists. Offering to clean it on uninstall prevents confusion about leftover files. | LOW | NSIS `MessageBox` during uninstall: "Remove temporary email files in %TEMP%\go-mapi? (These are deleted automatically during normal use.)" Remove on Yes. |
| Offline WebView2 installer fallback | Some RDS environments have no outbound internet access. Bundling the WebView2 standalone installer (80 MB, heavy) is an option for enterprise packages. | HIGH | Probably out of scope for v3.0. Document as a known enterprise deployment gap. Flag for later. |
| "Launch go-mapi after install" checkbox | Matches InnoSetup and NSIS convention. Avoids the awkward moment where the user finishes installing and nothing happens. | LOW | NSIS final page checkbox: checked by default. Runs `go-mapi.exe` after installer exits. |

#### Anti-Features

| Feature | Why Avoid | What to Do Instead |
|---------|-----------|-------------------|
| Requiring admin for every run (not just install) | The DLL copy and MAPI registry key legitimately need admin at install time. But the app itself must run as a normal user. | Separate concerns: installer runs elevated once; app binary registered to run as normal user. Never `ShellExecuteEx` with `runas` from within the running app. |
| Phoning home during install (telemetry, analytics, crash reporting) | Violates privacy model. | No network calls during install except the optional WebView2 bootstrapper download (which is a Microsoft URL, not a go-mapi URL). |
| Bundling a complete WebView2 Fixed Version runtime (250 MB+) in the installer | Makes the installer huge; unnecessary since Evergreen runtime is pre-installed on virtually all Win10/11 machines. | Use the 2 MB bootstrapper. Fall back to user-directed download from Microsoft if bootstrapper cannot run. |
| Leaving MAPI handler registered after uninstall | If go-mapi is uninstalled but the MAPI handler registry key remains, Windows will try to launch a missing binary when any app calls MAPISendMail. Silent failure for the end user's apps. | Uninstall removes `HKLM\SOFTWARE\Clients\Mail\go-mapi` unconditionally. |
| Installer that requires reboot | No file in this stack is locked by the OS at install time (DLL is only loaded by MAPI, which is per-process). Reboot requirement is unnecessary. | Do not schedule reboot. |

---

## Feature Dependencies

```
[System Tray icon + states]
    └──requires──> [Wails app running as background process]
    └──requires──> [Icon asset set (idle/active/queued/error)]
    └──enhances──> [Automode toggle] (context menu item)
    └──enhances──> [Queue count badge] (state derived from EmailWatcher)

[Toast Notifications]
    └──requires──> [AppUserModelID registration] (for persistent Action Center presence)
    └──requires──> [WinRT toast API accessible from Go]
    └──enhances──> [Automode] ("Draft created" confirmation toast)
    └──requires──> [System Tray] (app must be running to send toasts)

[Automode (Auto-draft / Auto-send)]
    └──requires──> [Desktop OAuth flow] (token needed for auto-actions)
    └──requires──> [EmailWatcher running in background goroutine]
    └──requires──> [Toast Notifications] (error fallback path)
    └──enhances──> [System Tray] (mode visible in tooltip/context menu)
    └──conflicts──> [Auto-send without undo window] (irreversibility risk)

[Desktop OAuth flow]
    └──requires──> [go-keyring / Windows Credential Manager] (secure token storage)
    └──requires──> [GCP project with desktop app OAuth client]
    └──enables──> [Automode] (tokens required for background API calls)
    └──enables──> [Toast "Draft created" confirmation]

[Autoupdate]
    └──requires──> [Stable GitHub Releases URL]
    └──requires──> [Config file with update_check_enabled flag]
    └──enhances──> [Installer UX] (users who click "Download" land on installer)
    (no dependency on OAuth or tray — standalone feature)

[Installer]
    └──requires──> [SignPath code signing] (SmartScreen reputation)
    └──requires──> [WebView2 runtime bootstrapper] (bundled 2MB)
    └──requires──> [NSIS script] (Wails build output)
    └──enables──> [System Tray] (registers app for autostart path if user opts in)
    └──enables──> [Desktop OAuth flow] (creates Credential Manager namespace)
    └──requires──> [Admin elevation] (MAPI registry key, DLL copy — install-time only)
```

### Dependency Notes

- **Toast notifications require AppUserModelID registration:** Unpackaged Win32 apps must register an AppUserModelID (AUMID) in the registry AND create a Start menu shortcut with the AUMID in its properties for toasts to persist in Action Center. Without this, toasts appear but immediately vanish from AC on dismissal. This is a hidden complexity — must be handled in the installer.
- **Automode requires OAuth:** Auto-draft and Auto-send both call the Gmail API. If the OAuth token is absent or expired and automode is active, the failure path (fallback to manual queue + error toast) is critical. This dependency means OAuth must be wired before automode can be meaningfully tested.
- **Auto-send undo window conflicts with instant-send:** A brief cancellation delay is not optional for Auto-send — it is the safety mechanism. The conflict here is: the undo window is a MEDIUM-complexity UI feature that must be built before Auto-send can ship safely.
- **Installer enables OAuth:** The installer creates the AUMID shortcut and registers the app, which is a prerequisite for persistent Action Center toasts and for the system to trust the Credential Manager namespace.

---

## MVP Definition

### Launch With (v3.0)

Minimum set that delivers the core value: non-technical Windows user can install once and have emails auto-drafted to Gmail without browser involvement.

- [x] System tray icon with 2 states (idle, error), right-click menu (Open, Quit), left-click to toggle window — basic tray presence
- [x] Toast notification on new email arrival (sender, subject, no body) — awareness without opening window
- [x] Desktop OAuth flow (loopback, PKCE, secure token storage) — replaces chrome.identity
- [x] Automode: Manual / Auto-draft only (no Auto-send in v3.0 — irreversibility risk without extensive undo testing) — core differentiator
- [x] Autoupdate notification (notify-only pattern; open browser for download) — keeps non-technical users current
- [x] NSIS installer with WebView2 bootstrapper + clean uninstall + AUMID registration — non-technical install UX

### Add After Validation (v3.x)

- [ ] Queue-count badge on tray icon — add when queue viewer is validated in real use
- [ ] "Draft now" action button on toast — add after toast infrastructure is stable
- [ ] Auto-send mode with undo window — add after user research confirms the use case is safe
- [ ] "Signed in as [email]" display + Sign out — add after OAuth is stable in production
- [ ] Release notes display in update banner — add after autoupdate check infrastructure exists

### Future Consideration (v4+)

- [ ] Per-email mode override — only if user research shows demand
- [ ] Offline WebView2 installer bundle — only if enterprise deployment is a priority
- [ ] Notification grouping header for multiple queued emails — low priority until queue volume justifies it
- [ ] Startup autostart toggle — add as an explicit user opt-in setting, not default

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| System tray icon (2 states, basic menu) | HIGH | LOW | P1 |
| Toast notification (new email) | HIGH | MEDIUM | P1 |
| Desktop OAuth (loopback + secure storage) | HIGH | MEDIUM | P1 |
| Automode (Manual / Auto-draft) | HIGH | MEDIUM | P1 |
| NSIS installer (WebView2 bootstrapper, AUMID, uninstall) | HIGH | MEDIUM | P1 |
| Autoupdate (notify-only) | MEDIUM | LOW | P1 |
| Queue-count badge on icon | MEDIUM | MEDIUM | P2 |
| Toast action buttons (Draft now, Dismiss) | MEDIUM | MEDIUM | P2 |
| "Signed in as" display + Sign out | MEDIUM | LOW | P2 |
| Mode toggle in context menu | LOW | LOW | P2 |
| Auto-send mode + undo window | HIGH | HIGH | P2 |
| Release notes in update banner | LOW | MEDIUM | P3 |
| Focus session suppression for toasts | LOW | LOW | P3 |
| Notification grouping (AC header) | LOW | MEDIUM | P3 |

**Priority key:**
- P1: Must have for v3.0 ship
- P2: Should have, add in v3.x point releases after validation
- P3: Nice to have, v4+

---

## Implementation Notes by Feature

### AppUserModelID for Toast Persistence

Unpackaged Win32 apps (which go-mapi will be — not MSIX packaged) must:
1. Set a unique AUMID string (e.g., `com.gomapi.app`) via `SetCurrentProcessExplicitAppUserModelID` Win32 call at startup.
2. Register a shortcut in `%APPDATA%\Microsoft\Windows\Start Menu\Programs\go-mapi.lnk` with the `System.AppUserModel.ID` shell property set to the same AUMID.
3. Optionally register `HKCU\Software\Classes\AppUserModelId\com.gomapi.app` with a `DisplayName` and `IconUri`.

Without step 2, toasts appear but do NOT persist in Action Center. The installer must create this shortcut. Wails does not handle this automatically.

### WinRT Toast from Go

The Go ecosystem has several options for WinRT toasts from unpackaged apps:
- `go-toast/toast` — simple, uses PowerShell internally, works for basic toasts but cannot do action buttons or AC persistence properly.
- Direct Win32/WinRT interop via `golang.org/x/sys/windows` — full control but significant boilerplate.
- `0xE232FCB` patched approaches — community solutions for the AUMID/COM activation path.

For v3.0: Use `go-toast/toast` for the initial implementation (covers table stakes). Upgrade to WinRT COM interop for action buttons (P2) after the basic infrastructure works.

### WebView2 Runtime on RDS

WebView2 Evergreen runtime is shared across all processes using the same Edge updater installation. On an RDS server with 30 users, if WebView2 is installed per-machine (which it will be if Microsoft Edge is installed, which it is on all modern Windows Server), all 30 go-mapi instances share a single copy of the WebView2 runtime binaries. The per-instance RAM overhead is ~15-30 MB for the renderer process (not 150+ MB like Electron which bundles its own Chromium). This matches the 10-30 MB budget from PROJECT.md — but needs measurement under real RDS load.

### OAuth Loopback Port Registration in GCP

Google allows desktop app OAuth clients to use ANY loopback port without pre-registering each one. Only the scheme and host (`http://127.0.0.1`) need to be registered as an authorized redirect URI in the GCP console — the port is ignored during validation for loopback URIs. This is explicitly documented in Google's loopback migration guide.

### Autoupdate Without Squirrel

The notify-and-open-browser pattern requires zero infrastructure beyond a GitHub repository:
1. On startup: `GET https://api.github.com/repos/marcfargas/go-mapi/releases/latest`
2. Parse `tag_name` (e.g., `v3.1.0`), compare with embedded `Version` constant.
3. If newer: show in-app banner with "Download v3.1.0" button.
4. Button opens `https://github.com/marcfargas/go-mapi/releases/latest` in browser.

No Squirrel, no helper process, no binary replacement. Sufficient for a solo FOSS project where updates are infrequent. Upgrade to `creativeprojects/go-selfupdate` (silent background download + prompt to restart) only if user research shows manual download is a friction point.

---

## Sources

- [Microsoft Learn: Toast UX Guidance (updated 2025-07-28)](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/toast-ux-guidance)
- [Microsoft Learn: App Notification Content](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/adaptive-interactive-toasts)
- [Microsoft Learn: WebView2 Distribution](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)
- [Google: OAuth 2.0 for Native Apps](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Google: Loopback Migration Guide](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration)
- [RFC 8252: OAuth 2.0 for Native Apps](https://www.rfc-editor.org/rfc/rfc8252.html)
- [zalando/go-keyring — Windows Credential Manager Go library](https://github.com/zalando/go-keyring)
- [creativeprojects/go-selfupdate — Go autoupdate library](https://github.com/creativeprojects/go-selfupdate)
- [fynelabs/selfupdate — Go selfupdate with ed25519 verification](https://github.com/fynelabs/selfupdate)
- [Wails system tray issues — GitHub](https://github.com/wailsapp/wails/issues/1521)
- [Wails v3 systray docs — v3alpha.wails.io](https://v3alpha.wails.io/features/menus/systray/)
- [Microsoft Learn: Single-click vs double-click tray discussion](https://learn.microsoft.com/en-us/archive/blogs/jonathanh/do-you-prefer-single-click-or-double-click-behavior-for-system-tray-icons)
- [SmartScreen reputation requirements 2025 — Advanced Installer](https://www.advancedinstaller.com/prevent-smartscreen-from-appearing.html)
- [Google OAuth Best Practices](https://developers.google.com/identity/protocols/oauth2/resources/best-practices)

---
*Feature research for: go-mapi v3.0 Wails Pivot — new Windows desktop behaviors*
*Researched: 2026-04-12*
