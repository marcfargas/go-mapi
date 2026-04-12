# Stack Research — go-mapi v3.0 Wails Pivot

**Domain:** Windows desktop app (Go + WebView2) replacing browser extension + native host split
**Researched:** 2026-04-12
**Confidence:** HIGH (Wails v2, WebView2 distribution, golang.org/x/oauth2, go-keyring, creativeprojects/go-selfupdate, fyne.io/systray) | MEDIUM (RAM estimates under RDS — requires real measurement)

## Scope Note

This document covers **new additions only** for the v3.0 Wails Pivot milestone. The existing stack that
is preserved unchanged: Go 1.21 + stdlib (watcher, MIME builder, Gmail API client), C++17/MinGW/CMake
(MAPI interceptor DLL), Inno Setup 6 (installer), SignPath Foundation (code signing), GitHub Actions CI.

The browser extension (TypeScript 5.3, React 18, Vite 5, Vitest 2, Playwright 1.58, `@changesets/cli`)
is **being retired** with this milestone.

---

## 1. Wails Framework

**Pick: Wails v2 (v2.12.0, stable). Do NOT use Wails v3 alpha.**

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| **github.com/wailsapp/wails/v2** | v2.12.0 (March 2026) | Go desktop app framework — wraps WebView2 on Windows, provides JS↔Go bridge, window management, build toolchain | Only stable Wails release; v3 is pre-release (alpha.74 as of March 2026 with explicit "may contain bugs" warning). v2.12.0 is the last v2 stable; matches Windows 10/11 target precisely. No macOS/Linux concern. |

**Why Wails v2 over v3 alpha:**
v3 has native system tray support, which is appealing, but it is automated nightly alpha software not
recommended for production. The system tray gap in v2 is solved by `fyne.io/systray` (see section 5).
Wails v3 will eventually stabilize but the migration cost at that point will be a known quantity —
migrating now means absorbing alpha churn on a solo project.

**Why Wails over alternatives:**
- vs Fyne/Gio: Wails provides a full webview layer, letting the UI stay HTML/CSS/JS; Fyne forces a Go-
  native widget system that is harder to style and requires a complete UI rewrite vs the existing React popup
- vs Tauri: Wails is Go-native; Tauri requires Rust. Adding a second compiled language to the stack that
  already has Go + C++ is not justified
- vs Electron: Electron bundles its own Chromium (~150MB). WebView2 reuses the Edge runtime already in
  memory on Windows, which is critical for the RDS target (30 concurrent users)

**Go version impact:** Wails v2 minimum is Go 1.21+. The existing `go.mod` (`go 1.21`) satisfies this.
No Go version bump is needed for Wails v2 itself. However, bumping to Go 1.23 is recommended because:
(a) `golang.org/x/oauth2` v0.36+ works best on current Go, (b) Go 1.22 introduced improved loop variable
semantics that avoid common goroutine capture bugs, (c) Go 1.23 is the version Wails explicitly tested
for macOS 15, suggesting it is the current "tested" baseline.

**Recommended Go bump: 1.21 → 1.23 (minimum).**

**Installation:**
```bash
# Wails CLI (dev toolchain only — not a runtime dependency)
go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0

# App go.mod (in the new Wails app module — not src/native-host/)
# go get github.com/wailsapp/wails/v2@v2.12.0
```

**Build:**
```bash
wails build -platform windows/amd64 -ldflags "-X main.Version=$VERSION"
```
Output: single `go-mapi.exe` (~10-15MB before WebView2 overhead).

---

## 2. WebView2 Runtime Distribution

**Pick: Evergreen Bootstrapper (per-machine install, silent). Do NOT bundle Fixed Version.**

| Approach | Installer size | Updates | RDS RAM | Verdict |
|----------|---------------|---------|---------|---------|
| **Evergreen Bootstrapper** (~2MB) | +2MB to installer | Automatic, shared with Edge | Shared browser process across apps on same UDF | **Use this** |
| Evergreen Standalone (~130MB) | +130MB to installer | Automatic | Same as above | Use only for offline RDS environments |
| Fixed Version (~250MB) | +250MB to installer | Manual (you ship updates) | Isolated per-app | Avoid — adds 250MB to installer, requires manual security patching |

**Rationale for Evergreen Bootstrapper:**

The Inno Setup installer should detect WebView2 presence via registry key
`HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` and
only run the bootstrapper if absent. On Windows 11 (the primary target) WebView2 is pre-installed OS-
wide. On Windows 10 it is present on the vast majority of devices since Microsoft pushed it via Windows
Update (2022). The bootstrapper handles the rare missing case with a 2MB download.

**RDS RAM model:** Multiple `go-mapi.exe` instances on the same server can share one WebView2 browser
process if they use the same user data folder (UDF). Wails v2 defaults to an app-specific UDF. To
enable process sharing across 30 RDS user sessions, configure all instances to use a shared UDF path
(e.g., `C:\ProgramData\go-mapi\webview2`). This means the 30 sessions share one browser process rather
than spawning 30. The Go + WebView2 per-instance overhead then drops to ~15-30MB for the renderer
process, versus ~100-200MB per instance without sharing. This needs measurement during v3.0 development
but is the correct architectural target.

**CRITICAL for RDS:** Use per-machine WebView2 install (run bootstrapper from elevated/admin context in
Inno Setup). Per-user installs on RDS cause one WebView2 installation attempt per user login — this
breaks shared environments. The Inno Setup installer must run with admin privileges (already the case
for v2.0 DLL registration).

**Fixed Version is NOT recommended** because: it adds 250MB+ to installer, requires manual security
patching each time a WebView2 CVE ships, and prevents UDF sharing (each app gets its own browser
process). The RAM benefit of UDF sharing outweighs any version-control argument for this use case.

---

## 3. Google OAuth 2.0 Desktop Flow

**Pick: `golang.org/x/oauth2` with loopback redirect + PKCE. No external browser-launcher library.**

### 3a. OAuth Library

| Library | Version | Purpose | Why Recommended |
|---------|---------|---------|-----------------|
| **golang.org/x/oauth2** | v0.36.0 (Feb 2026) | OAuth 2.0 token exchange, token refresh, PKCE support | Official Go extended library; already the correct choice for Gmail API auth. Handles loopback redirect natively via `Config.RedirectURL = "http://127.0.0.1:PORT"`. PKCE support added via `GenerateVerifier()` / `S256ChallengeOption()` / `VerifierOption()`. No additional library needed. |

**Flow:**
1. Start a local HTTP server on a random port (stdlib `net/http` with `net.Listen("tcp", "127.0.0.1:0")`)
2. Build auth URL: `conf.AuthCodeURL(state, oauth2.AccessTypeOffline, oauth2.S256ChallengeOption(verifier))`
3. Open browser to that URL: `wails.BrowserOpenURL(ctx, authURL)` — Wails built-in, no extra library
4. Local server receives redirect with `?code=...`, exchanges via `conf.Exchange(ctx, code, oauth2.VerifierOption(verifier))`
5. Store token (see 3b)

**Google OAuth application type:** "Desktop app" (not "Web application"). This is a different OAuth
client type in Google Cloud Console — it does not require client secret confidentiality and allows
loopback redirect URIs without pre-registration of the exact port.

**Scopes (unchanged from v2.x):**
- `https://www.googleapis.com/auth/gmail.compose`
- `https://www.googleapis.com/auth/gmail.send`

**Important:** The existing `gmail.go` `CreateDraft()` function takes a bearer token string and calls
the Gmail REST API directly — this remains unchanged. The new OAuth flow produces a `*oauth2.Token`;
extract `token.AccessToken` and pass to the existing function. Token refresh is handled by
`oauth2.TokenSource` wrapping the stored token.

### 3b. Token Storage

**Pick: `github.com/zalando/go-keyring` (v0.2.8, Mar 2026). Uses Windows Credential Manager (DPAPI-backed).**

| Library | Version | Windows backend | Why Recommended |
|---------|---------|----------------|-----------------|
| **github.com/zalando/go-keyring** | v0.2.8 | Windows Credential Manager | Simple 3-function API (`Set`/`Get`/`Delete`); Windows Credential Manager is DPAPI-encrypted per-user — tokens are not accessible to other users or processes; cross-platform API for future non-Windows support |

**Why not `99designs/keyring`:** More backends, more complexity. For this project, Windows-only is
sufficient for v3.0 and `go-keyring` is simpler. The 3-function API is all that's needed.

**Why not `github.com/billgraziano/dpapi` directly:** go-keyring provides the right abstraction level.
Direct DPAPI would require implementing the key-value storage layer manually.

**Token storage pattern:**
```go
// Store (after OAuth exchange)
keyring.Set("go-mapi", "gmail-token", tokenJSON)

// Retrieve (on startup)
tokenJSON, err := keyring.Get("go-mapi", "gmail-token")

// Delete (on sign-out)
keyring.Delete("go-mapi", "gmail-token")
```

Store the full `oauth2.Token` JSON (marshal with `encoding/json`), including the refresh token, so the
app can silently refresh without re-authenticating on every launch.

**RDS concern:** Each Windows user session has its own Credential Manager vault. 30 users each store
their own Gmail token. This is correct behavior — each user authenticates with their own Google account.

---

## 4. Frontend Inside Wails

**Pick: Svelte 5 with TypeScript. Do NOT use React or vanilla TS.**

| Framework | Bundle size | RAM overhead | DX | Verdict |
|-----------|------------|--------------|-----|---------|
| **Svelte 5** | ~1.85KB base | Minimal (compiler output, no runtime) | Excellent | **Use this** |
| Vanilla TS | 0KB framework | Minimal | High boilerplate for reactive UI | Acceptable fallback |
| React 18 | ~42KB (compressed) | Virtual DOM runtime always in memory | Familiar (existing popup code) | Avoid — over-engineered for this queue viewer |
| SolidJS | ~7KB | Minimal (fine-grained reactivity) | Good | Valid alternative to Svelte |

**Why Svelte 5 over React:**
The existing React popup has ~200 lines of components. That small a UI does not justify React's ~42KB
runtime that stays resident in every WebView2 renderer. Svelte compiles to vanilla JS — no framework
runtime in the final bundle. For 30 concurrent RDS users, the renderer process memory savings from
eliminating the React runtime are measurable.

**Why Svelte 5 over Vanilla TS:**
The queue viewer needs reactive state (email list updates when watcher fires, badge count updates,
mode toggle). Without a reactive layer this devolves into manual DOM manipulation that Svelte handles
with zero runtime cost.

**Wails + Svelte integration:** Wails has a first-party `svelte-ts` template:
```bash
wails init -n go-mapi -t svelte-ts
```
This sets up Vite + Svelte + TypeScript with the Wails JS runtime bindings pre-wired. The existing
Wails JS API (`window.go.*`) bridges to bound Go functions automatically.

**Do NOT add:**
- React Bootstrap or Bootstrap — CSS-only styling (Tailwind CSS or plain CSS) is appropriate for this
  small UI. Bootstrap adds ~30KB of CSS to every renderer.
- i18n library — internal tool, Spanish UI per project conventions, but that's a string-in-code matter
  not a library matter for this scope.

---

## 5. System Tray

**Pick: `fyne.io/systray` v1.12.0 via `RunWithExternalLoop`. Do NOT use getlantern/systray or systray-on-wails.**

| Library | Version | Wails v2 compatibility | Verdict |
|---------|---------|----------------------|---------|
| **fyne.io/systray** | v1.12.0 (Dec 2025) | YES — `RunWithExternalLoop` returns start/end hooks | **Use this** |
| github.com/getlantern/systray | latest | NO — conflicts with Wails main thread on Windows | Avoid |
| github.com/ra1phdd/systray-on-wails | v0.0.0-20241115 | Partial — unmaintained (0-version pre-release, one maintainer) | Avoid |
| Built-in Wails v2 tray | N/A | Does not exist in v2 | N/A |
| Wails v3 built-in tray | N/A | v3 is alpha | Defer to v3 migration |

**Why `fyne.io/systray` works with Wails v2:**
Wails v2 owns the Windows message loop (WndProc). `getlantern/systray` and its forks also try to own
it via their own `Run()` — two owners = deadlock. `fyne.io/systray` specifically added
`RunWithExternalLoop` to support frameworks that own the message loop:

```go
// In Wails OnStartup callback (not in main()):
start, end := systray.RunWithExternalLoop(onTrayReady, onTrayExit)
start()
// ... rest of Wails startup
// In OnShutdown:
end()
```

`RunWithExternalLoop` registers the tray icon using Windows Shell APIs without taking the message loop.
Wails delivers `WM_USER` messages from the shell notification area to fyne.io/systray callbacks via
its own loop.

**Requires CGO** (`CGO_ENABLED=1` — already required for Wails itself on Windows).

**Tray implementation pattern for go-mapi:**
- Icon: embed PNG with `//go:embed` + `systray.SetIcon()`
- Tooltip: `"go-mapi — N pending"` updated on queue changes via `systray.SetTooltip()`
- Menu items: "Open", "---", "Sign out", "Quit"
- `OnBeforeClose` in Wails options: return `true` (prevent close), call `runtime.WindowHide(ctx)` — window
  hides to tray instead of terminating
- Double-click tray icon: call `runtime.WindowShow(ctx)` to restore

---

## 6. Autoupdate

**Pick: `creativeprojects/go-selfupdate` v1.5.2 for update-check-and-notify. Actual install via signed Inno Setup re-run. Do NOT implement in-place binary replacement.**

### Rationale

Wails has no built-in autoupdate mechanism. Two approaches exist:

**Approach A (recommended): Check + notify → installer re-run**
1. On startup (or on timer), call GitHub Releases API to check latest tag
2. If newer, show in-app toast: "Update available — click to download"
3. On click, open browser to installer download URL (stable URL pattern from v2.0)
4. User downloads and runs the new signed Inno Setup installer (which handles DLL, registry, binary replacement)

This approach preserves code signing integrity — the installer is the signed artifact, and re-running
it is the correct update path. No unsigned binary replacement happens.

**Approach B (rejected): In-place binary replacement via minio/selfupdate**
minio/selfupdate (v0.6.0, last updated Oct 2022, maintenance status: inactive) can atomically replace
the running binary. Problems: (a) the replacement binary must be separately signed or SmartScreen will
block it; (b) it does not update the DLL, registry entries, or Inno Setup uninstall records; (c) minio/
selfupdate is not actively maintained. This approach is incomplete for an installer-based distribution.

| Library | Version | Purpose | Why Recommended |
|---------|---------|---------|-----------------|
| **github.com/creativeprojects/go-selfupdate** | v1.5.2 (Dec 2025) | Check GitHub Releases for newer version, return version info | Actively maintained (MIT, Dec 2025), supports GitHub releases natively, provides rollback, handles multi-arch. Used only for VERSION DETECTION — not binary replacement. |

**Usage (version check only):**
```go
import "github.com/creativeprojects/go-selfupdate"

func checkForUpdate(currentVersion string) (*selfupdate.Release, bool, error) {
    latest, found, err := selfupdate.DetectLatest(context.Background(),
        selfupdate.ParseSlug("marcfargas/go-mapi"))
    if err != nil || !found {
        return nil, false, err
    }
    if latest.GreaterThan(currentVersion) {
        return latest, true, nil
    }
    return nil, false, nil
}
```

Then show in-app notification; open browser to the stable download URL on confirmation.

**The stable download URL pattern** (from v2.0 installer milestone) serves the installer directly.
`go-selfupdate` gives you the version comparison logic; the download itself is handled by the existing
Inno Setup installer delivery mechanism.

**PROJECT.md states:** "Host self-update (auto-download + replace) — not a priority; users re-run the
installer for updates." This is listed under Out of Scope. Approach A (check + notify) is exactly the
right scope boundary: users know about updates, but the install action is explicit.

---

## 7. Code Signing

**No changes needed to SignPath configuration.** The new artifact is `go-mapi.exe` (Wails build output)
instead of `go-mapi-host.exe`. SignPath signs PE binaries — the output format is identical. The Inno
Setup `.exe` installer is also already signed via SignPath.

**What changes:**
- Binary filename: `go-mapi-host.exe` → `go-mapi.exe` (or `go-mapi-app.exe` — to be decided at
  implementation). Update SignPath artifact configuration entry to match new filename.
- The extension `.crx` signing step goes away (extension retired).
- The Inno Setup installer signing step is unchanged.

**What does NOT change:**
- SignPath Foundation OSS project enrollment (already approved)
- The CI signing workflow pattern (`signpath/github-action-submit-signing-request`)
- PE certificate type (Authenticode)
- SmartScreen reputation: new binary name resets SmartScreen reputation to zero. Mitigate by
  incrementally building reputation via the same stable download URL; document the "Windows may warn
  on first install" UX in the release notes.

**Wails signing note:** Wails `wails build` produces a standard Windows PE binary. No Wails-specific
signing steps exist. Sign the output binary the same way as the current Go host binary.

---

## 8. Go Version Bump

**Bump go.mod from `go 1.21` to `go 1.23`.**

| Reason | Detail |
|--------|--------|
| Wails v2.9.3+ tested with Go 1.24 | go 1.23 is the safe minimum for compatibility; Wails docs state Go 1.21+ minimum |
| golang.org/x/oauth2 v0.36.0 | Uses Go generics-adjacent patterns; builds cleanly on 1.21+ but 1.23 avoids any edge cases |
| Loop variable capture fix | Go 1.22 changed `for` loop variable scoping, eliminating a class of goroutine bugs present in the watcher/debounce loop |
| go-keyring v0.2.8 | No specific Go minimum stated; 1.21+ sufficient |
| fyne.io/systray v1.12.0 | States Go 1.12+; 1.23 is fine |

**The Wails app will be a NEW Go module** (e.g., `github.com/marcfargas/go-mapi/app`) separate from
`src/native-host/` (which retires as a standalone module). The new module starts at `go 1.23`.

The C++ interceptor DLL and its build toolchain are unchanged — no Go version impact there.

---

## Recommended Stack Summary

### Core Technologies

| Technology | Version | Purpose | Integration Point |
|------------|---------|---------|-------------------|
| **github.com/wailsapp/wails/v2** | v2.12.0 | Desktop app shell, WebView2 bridge, window management | New `src/app/` module; replaces `src/native-host/` + `src/extension/` |
| **WebView2 Evergreen Bootstrapper** | Latest (auto) | Browser engine for UI rendering | Inno Setup installer detects + downloads if absent; per-machine install |
| **golang.org/x/oauth2** | v0.36.0 | Google OAuth 2.0 desktop flow with PKCE | New `oauth.go` in app module; `token.AccessToken` fed to existing `gmail.go` |
| **github.com/zalando/go-keyring** | v0.2.8 | Windows Credential Manager token storage | New `auth.go`; `Set`/`Get`/`Delete` around token JSON |
| **fyne.io/systray** | v1.12.0 | System tray icon + context menu | Wails `OnStartup` hook via `RunWithExternalLoop` |
| **github.com/creativeprojects/go-selfupdate** | v1.5.2 | Update version detection from GitHub Releases | Background goroutine on startup; result shown as in-app toast |
| **Svelte 5 + TypeScript** | Svelte 5.x | Queue viewer UI | Wails `svelte-ts` template; replaces React popup |

### Supporting Libraries (Unchanged from v2.x, migrated to new module)

| Library | Version | Purpose | Status |
|---------|---------|---------|--------|
| **github.com/fsnotify/fsnotify** | v1.7.0 | File system watching for email JSON files | Migrates to new app module unchanged |
| **golang.org/x/sys** | v0.4.0+ | Windows system calls | Migrates; may version-bump with new dependencies |

### Retired with v3.0

| Technology | Was Used For | Replacement |
|------------|-------------|-------------|
| Chrome/Edge Native Messaging protocol | Go↔Extension IPC | Wails Go↔JS bridge |
| React 18 + React-Bootstrap | Extension popup UI | Svelte 5 in Wails webview |
| Vite 5 | Extension bundle | Vite (embedded in Wails svelte-ts template) |
| `chrome.identity.getAuthToken()` | OAuth | golang.org/x/oauth2 loopback flow |
| `chrome.storage.session` | Email queue state | In-memory Go map (existing watcher) |
| `@changesets/cli` extension track | Extension versioning | Extension retired; single app version |

---

## Installation

```bash
# 1. Install Wails CLI (dev machine only)
go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0

# 2. Initialize new app module (run once)
wails init -n go-mapi -t svelte-ts

# 3. Add Go dependencies to new app module
cd src/app
go get github.com/wailsapp/wails/v2@v2.12.0
go get golang.org/x/oauth2@v0.36.0
go get github.com/zalando/go-keyring@v0.2.8
go get fyne.io/systray@v1.12.0
go get github.com/creativeprojects/go-selfupdate@v1.5.2
go get github.com/fsnotify/fsnotify@v1.7.0

# 4. Build
wails build -platform windows/amd64 -ldflags "-s -w -X main.Version=$VERSION"
```

---

## Alternatives Considered

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| Wails v2.12.0 (stable) | Wails v3 alpha | v3 is automated nightly alpha; "may contain bugs"; no production use recommendation from maintainers |
| Wails | Tauri | Requires Rust; adding a third compiled language to Go + C++ stack is unjustified |
| Wails | Electron | Bundles full Chromium (~150MB installer hit); WebView2 is already on Windows 10/11 |
| Wails | Fyne | Go-native widgets, no web UI layer; incompatible with future in-app composer (HTML form) |
| Evergreen Bootstrapper | Fixed Version WebView2 | Fixed Version adds 250MB to installer and requires manual security updates per CVE |
| golang.org/x/oauth2 | google/oauth2 (deprecated) | golang.org/x/oauth2 is the canonical maintained path |
| go-keyring (zalando) | 99designs/keyring | More complex API with more backends; go-keyring's 3-function API is sufficient and simpler |
| go-keyring (zalando) | billgraziano/dpapi directly | DPAPI is the backend, not the KV store; go-keyring provides the store layer |
| fyne.io/systray | getlantern/systray | getlantern/systray conflicts with Wails message loop on Windows |
| fyne.io/systray | ra1phdd/systray-on-wails | 0-version pre-release, single maintainer, no recent activity |
| creativeprojects/go-selfupdate | minio/selfupdate | minio/selfupdate last updated Oct 2022, maintenance status inactive |
| Svelte 5 | React 18 | React adds ~42KB runtime resident in renderer; Svelte compiles to vanilla JS with zero runtime |
| Installer re-run update | In-place binary replace | Binary replace does not update DLL/registry; replaced binary loses SignPath signature |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Wails v3 alpha | Pre-release, nightly automated builds, explicit "may contain bugs" | Wails v2.12.0 stable |
| Electron | ~150MB Chromium bundled; per-instance ~200MB RAM — unacceptable for 30-user RDS | Wails v2 + WebView2 |
| WebView2 Fixed Version | +250MB installer, no auto security updates, prevents UDF sharing | Evergreen Bootstrapper |
| getlantern/systray | Conflicts with Wails Windows message loop | fyne.io/systray with RunWithExternalLoop |
| minio/selfupdate for in-place update | Inactive (2022), does not update DLL/registry, signed binary concerns | Version-check only via creativeprojects/go-selfupdate + installer re-run |
| React 18 in Wails frontend | ~42KB runtime overhead × 30 RDS instances; overkill for this queue viewer | Svelte 5 |
| Per-user WebView2 install on RDS | One install attempt per user login, breaks shared environments | Per-machine install from elevated Inno Setup |

---

## Version Compatibility

| Package | Go Minimum | Compatible With | Notes |
|---------|-----------|----------------|-------|
| github.com/wailsapp/wails/v2@v2.12.0 | Go 1.21 | Windows 10/11, WebView2 | CGO required; requires Node 15+ for frontend build |
| golang.org/x/oauth2@v0.36.0 | Go 1.21 | Any | PKCE via GenerateVerifier/S256ChallengeOption |
| github.com/zalando/go-keyring@v0.2.8 | Go 1.12 | Windows Credential Manager | CGO required on Windows |
| fyne.io/systray@v1.12.0 | Go 1.12 | Windows Shell | CGO required; use RunWithExternalLoop with Wails |
| github.com/creativeprojects/go-selfupdate@v1.5.2 | Go 1.21 | GitHub Releases API | MIT license |
| github.com/fsnotify/fsnotify@v1.7.0 | Go 1.17 | Windows filesystem | Unchanged from v2.x |

All packages require CGO or are CGO-safe. CGO is already required for Wails itself. No CGO conflict.

---

## Sources

- [pkg.go.dev/github.com/wailsapp/wails/v2](https://pkg.go.dev/github.com/wailsapp/wails/v2) — v2.12.0 confirmed (Mar 2026)
- [github.com/wailsapp/wails/releases](https://github.com/wailsapp/wails/releases) — v3 alpha status confirmed, v2.12.0 latest stable
- [deepwiki.com/wailsapp/wails/2.1-installation](https://deepwiki.com/wailsapp/wails/2.1-installation) — Go 1.21+ minimum, Windows requirements confirmed HIGH confidence
- [v3alpha.wails.io/whats-new/](https://v3alpha.wails.io/whats-new/) — v3 system tray feature exists; v3 is pre-release
- [learn.microsoft.com WebView2 Distribution](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution) — Evergreen Bootstrapper vs Fixed Version tradeoffs, RDS per-machine install guidance HIGH confidence
- [learn.microsoft.com WebView2 Process Model](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/process-model) — UDF sharing = shared browser process; renderer process model HIGH confidence
- [pkg.go.dev/golang.org/x/oauth2](https://pkg.go.dev/golang.org/x/oauth2) — v0.36.0 (Feb 2026), PKCE API confirmed HIGH confidence
- [developers.google.com OAuth2 Native App](https://developers.google.com/identity/protocols/oauth2/native-app) — loopback redirect pattern for desktop apps HIGH confidence
- [pkg.go.dev/github.com/zalando/go-keyring](https://pkg.go.dev/github.com/zalando/go-keyring) — v0.2.8 (Mar 2026), Windows Credential Manager backend confirmed HIGH confidence
- [pkg.go.dev/fyne.io/systray](https://pkg.go.dev/fyne.io/systray) — v1.12.0 (Dec 2025), RunWithExternalLoop confirmed HIGH confidence
- [github.com/wailsapp/wails/discussions/4514](https://github.com/wailsapp/wails/discussions/4514) — getlantern/systray conflicts with Wails v2 message loop confirmed MEDIUM confidence
- [pkg.go.dev/github.com/creativeprojects/go-selfupdate](https://pkg.go.dev/github.com/creativeprojects/go-selfupdate) — v1.5.2 (Dec 2025), MIT, GitHub releases source HIGH confidence
- [pkg.go.dev/github.com/minio/selfupdate](https://pkg.go.dev/github.com/minio/selfupdate) — v0.6.0 (Oct 2022), inactive maintenance HIGH confidence

---

*Stack research for: go-mapi v3.0 Wails Pivot*
*Researched: 2026-04-12*
