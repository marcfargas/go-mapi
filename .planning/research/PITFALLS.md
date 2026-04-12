# Pitfalls Research — go-mapi v3.0 Wails Pivot

**Domain:** Wails (Go + WebView2) desktop app — Windows-only, RDS deployment, Google OAuth desktop flow, MAPI integration, self-update, signed installer
**Researched:** 2026-04-12
**Confidence:** MEDIUM-HIGH (WebView2 memory numbers partially estimated; no public RDS-at-30-users benchmark exists; OAuth, signing, and ecosystem pitfalls are HIGH confidence from official docs)

> **Scope note:** These pitfalls are specific to the v3.0 workstream — replacing the Chrome/Edge extension with a standalone Wails desktop app. The existing MAPI DLL, filesystem IPC, and privacy model are unchanged. Migration risks (clean break from v2.x) are also covered.

---

## Critical Pitfalls

### Pitfall 1: WebView2 RAM budget in RDS is not what the marketing claim implies

**What goes wrong:**
"WebView2 shares the Edge runtime process" is a recurring claim in Electron-vs-WebView2 comparisons. It is partially true at the binary/DLL level — the WebView2 Runtime is the same Edge engine — but each WebView2 process group still spawns its own browser process, one or more renderer processes, a GPU process, and helper processes. At 30 concurrent RDS users, each running go-mapi as a separate user-session app, you get 30 independent WebView2 process groups. There is no cross-session process sharing; Windows isolates user sessions at the HDESKTOP level, and the WebView2 UDF (user data folder) cannot be shared across sessions. The official docs state "each renderer process takes around 30 MB memory," and a browser process adds overhead on top. An idle Wails app with a simple queue UI may consume 80–150 MB per user session (Go binary ~15 MB + WebView2 processes 60–120 MB), putting the 30-user total at 2.4–4.5 GB RAM — well above the 10–30 MB per-instance target stated in PROJECT.md.

**Why it happens:**
The comparison point is always Electron (which bundles ~130 MB of Chromium per app), and WebView2 does win that comparison. But the implicit baseline of "10–30 MB per instance" comes from the old go-mapi-host.exe (a lean Go binary with no UI). Wails adds a WebView2 layer that is inherently process-heavy. Teams discover this only during load testing, after the architecture is committed.

**How to avoid:**
- Measure before committing: set up a minimal Wails "hello world" app on a Windows Server VM with RDP multi-session, launch it as 5–10 simultaneous users, and record RSS for each msedgewebview2.exe process group using Process Monitor. Extrapolate to 30.
- Use `CoreWebView2MemoryUsageTargetLevel.Low` via Wails' WebView2 environment options when the go-mapi window is hidden (tray-only mode). This instructs the engine to drop cached data and reduce working set.
- Expose a build flag or config option so RDS deployments can run in a "headless" mode — skip loading the WebView2 window until the user explicitly opens it (lazy init). If the app is 95% tray-resident, defer WebView2 initialization to first open.
- If RAM is still over budget after these mitigations, evaluate whether the Wails UI could be replaced with a pure Win32/GDI queue dialog for the RDS tier, keeping Wails only for the full desktop install. This is a significant fallback but must be identified early.

**Warning signs:**
- Task Manager shows >150 MB committed per go-mapi user session on Windows Server
- RDS server OOMs under normal load after go-mapi is deployed
- `msedgewebview2.exe` appears multiple times per user session in Task Manager (expected; signals full process group, not sharing)

**Phase to address:** Phase 1 — Wails shell prototype. Measure RAM in a simulated multi-session environment before any feature work. Gate on "RAM ≤ 80 MB per session in tray-only mode" before proceeding.

---

### Pitfall 2: WebView2 Evergreen runtime not present — installer fails silently on locked-down servers

**What goes wrong:**
The Evergreen WebView2 bootstrapper is a 2 MB downloader that fetches the runtime from Microsoft CDN at install time. On RDS servers in corporate environments, outbound internet access may be blocked, or the server may already have a WebView2 Runtime version locked by Group Policy. The bootstrapper's `/silent /install` mode has a documented exit-timing bug: it exits before installation completes (returning control to the parent NSIS/WiX installer), causing the installer to proceed as if WebView2 is ready while it is still installing (or has failed). The app then crashes on first launch with a WebView2 initialization error that shows nothing to the user — the window simply does not appear.

**Why it happens:**
The bootstrapper was designed for consumer deployments where internet is available. The timing bug (GitHub issue MicrosoftEdge/WebView2Feedback#1349) means `/silent /install` is not reliably waitable from a parent installer. Server environments with CDN restrictions or air-gap policies are common in enterprise RDS deployments, which is exactly go-mapi's primary target.

**How to avoid:**
- Bundle the Evergreen standalone installer (the full offline `.exe`, not the bootstrapper) in the go-mapi installer package. This avoids CDN dependency at install time. The trade-off is installer size (~250 MB added for the WebView2 standalone installer if included), but it can be a separate download option ("enterprise installer").
- Alternatively, check for WebView2 presence before launching the installer UI, and show a clear "WebView2 required" message with a direct download link if absent.
- Use the Fixed Version Runtime only if enterprise reproducibility is critical — it adds >250 MB to the package and requires manual updates (the Fixed Version no longer includes non-English localizations above a certain version).
- In the installer, detect WebView2 presence by checking the registry key `HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` before attempting installation.
- Consider NSIS's `ExecWait` with an explicit poll loop for the WebView2 process to exit rather than relying on the bootstrapper's exit code.

**Warning signs:**
- go-mapi installer completes but app shows a blank window on first launch
- Event log contains `HRESULT 0x80070490` (element not found) from WebView2 init
- The install succeeds on developer machines (which have Edge/WebView2 from prior software installs) but fails on freshly imaged RDS servers

**Phase to address:** Phase 4 — Installer build. Implement and test on a clean Windows Server VM with no Edge pre-installed before publishing.

---

### Pitfall 3: Google OAuth consent screen 100-user hard cap — hits RDS deployments immediately

**What goes wrong:**
Any Google OAuth app using sensitive or restricted scopes (gmail.compose and gmail.send are sensitive) that has not completed Google's verification process is capped at 100 unique users over the lifetime of the GCP project. This is not 100 concurrent users — it is 100 distinct Google accounts that have ever granted the app permission. The cap cannot be reset and does not reset when users revoke. At 30 RDS users, a single deployment server consumes 30% of the cap. A second RDS customer exhausts it. New users beyond 100 see a "This app is unverified" error and cannot proceed.

**Why it happens:**
The unverified app screen and 100-user cap are widely known for web apps, but desktop OAuth apps (using loopback redirect) are subject to the same rules. The current go-mapi extension uses `chrome.identity.getAuthToken()` which routes through Chrome's own verified OAuth client, bypassing this. The new desktop OAuth flow uses go-mapi's own GCP client ID, which starts unverified.

**How to avoid:**
- Submit for Google OAuth verification before the v3.0 public release, not after. Verification for sensitive scopes (gmail.compose, gmail.send) requires: app description, privacy policy URL, demo video walkthrough, and brand verification. Plan 4–8 weeks for review.
- While waiting for verification, the existing GCP project can be set to "Testing" mode with an allowlist of up to 100 test users — use this for beta deployments only.
- If verification is delayed, publish v3.0 with clear documentation that users must add themselves to a test-user allowlist via the Google Cloud Console. This is not viable for non-technical users.
- Ensure the privacy policy exists and is reachable at a stable public URL before submitting — this is a hard blocker for verification.

**Warning signs:**
- Users beyond the first ~100 see "This app hasn't been verified by Google" and cannot complete sign-in
- GCP console shows "User cap reached" in the OAuth consent screen
- Beta users who previously authorized the old extension (via Chrome identity) have no issue, but new v3.0 users are blocked

**Phase to address:** Phase 2 — OAuth implementation. Submit verification at the start of Phase 2, not the end. Begin immediately after the GCP OAuth client is created.

---

### Pitfall 4: OAuth loopback redirect — port conflicts and firewall prompts on RDS

**What goes wrong:**
The desktop OAuth flow works by starting a local HTTP server on a random ephemeral port, then opening the browser to Google's auth endpoint with `redirect_uri=http://127.0.0.1:{port}/callback`. Two failure modes occur in RDS environments:

1. **Port conflict**: Multiple go-mapi users on the same RDS server all attempt to bind to an ephemeral port simultaneously. OS port allocation should prevent actual collision (each gets a different port), but some corporate firewall software monitors and blocks unexpected inbound connections on localhost, treating them as suspicious.

2. **Windows Firewall dialog**: The first time go-mapi's HTTP server binds to a port and accepts a connection, Windows Firewall may show a "Do you want to allow go-mapi to communicate on these networks?" prompt. On RDS, this can appear on the server console (not the user's RDP session), is invisible to the user, and effectively freezes the OAuth flow.

**Why it happens:**
Google deprecated the loopback-via-localhost approach in favor of `http://127.0.0.1` (IP, not hostname) precisely because `localhost` resolution can fail or be blocked. But even with `127.0.0.1`, Windows treats an app listening on any port as a network activity requiring firewall approval — unless the firewall rule is pre-created by the installer.

**How to avoid:**
- Use `http://127.0.0.1` (not `localhost`) as the redirect URI, as documented by Google's loopback migration guide. Register this in the GCP console as an authorized redirect URI with no port specified — Google allows any port for loopback URIs.
- In the installer, create a Windows Firewall inbound rule for go-mapi.exe to prevent the on-first-use dialog: `New-NetFirewallRule -DisplayName "go-mapi OAuth" -Direction Inbound -Program "$installDir\go-mapi.exe" -Action Allow`.
- Bind to port 0 (OS-assigned), then use the actual assigned port in the redirect_uri — this guarantees no fixed-port collision.
- Add a 30-second timeout on the local HTTP server; if no callback arrives, show "Authorization timed out — please try again" and close the server.

**Warning signs:**
- OAuth flow opens the browser but the app hangs indefinitely after the user grants permission
- Firewall event log shows `go-mapi.exe` connection blocked
- Users on RDS report the browser opened and Google showed "approved" but the app never updated its state

**Phase to address:** Phase 2 — OAuth implementation. Test the full flow on Windows Server with default firewall settings, not just on developer workstations.

---

### Pitfall 5: OAuth refresh token silent invalidation — user loses access without notification

**What goes wrong:**
Google invalidates OAuth refresh tokens when: (1) the user revokes app access from their Google Account settings, (2) the token has not been used for 6 months, (3) the user changes their Google password and the token has gmail scopes, (4) the OAuth app is in "Testing" mode and the token exceeds 7 days (testing-mode tokens expire in 7 days), or (5) the user account exceeds 100 live refresh tokens for the client ID. When the token is invalidated, the next `drafts.create` call returns HTTP 401. The current Go code (`gmail.go`) has no retry-on-401 logic — it sends a `draft-error` message and the user sees a failure notification with no guidance. The token is stored, the app appears functional, but every MAPI action silently fails until the user re-authenticates.

**Why it happens:**
The current extension delegates token lifecycle to Chrome Identity API, which handles refresh transparently. The new desktop flow owns the token entirely and must implement its own refresh/revocation detection. The 7-day expiry for "Testing" mode apps is a particularly sharp edge during development.

**How to avoid:**
- On any 401 from the Gmail API, clear the stored token and trigger the OAuth flow again, showing a notification: "Gmail sign-in required — click to re-authorize."
- Implement a background token validity check at app startup (a cheap `oauth2/v1/tokeninfo` call or an attempt to refresh the access token) rather than discovering invalidation only on the first MAPI event.
- Store the token in Windows Credential Manager (see Pitfall 6) and associate a "last used" timestamp; schedule a weekly no-op refresh to prevent 6-month idle expiry.
- During development, never use "Testing" mode refresh tokens in integration test fixtures — they will expire in 7 days and break CI.

**Warning signs:**
- App shows "Draft created" notification but no draft appears in Gmail
- App shows `draft-error` repeatedly without any user action having changed
- Google Account's "Third-party apps" page does not list go-mapi (indicates prior revocation)

**Phase to address:** Phase 2 — OAuth implementation. Implement 401-triggered re-auth before any end-to-end testing. Test token revocation explicitly (revoke from Google Account → verify app prompts re-auth).

---

### Pitfall 6: Token storage in RDS — DPAPI scope and roaming profile complications

**What goes wrong:**
The natural choice for secure token storage on Windows is Windows Credential Manager (via `wincred` or the `keyring` Go library), which uses DPAPI to encrypt credentials tied to the user's Windows login. In RDS environments with roaming profiles, DPAPI encryption is tied to the user's profile on the specific server where it was created. If the user logs into a different RDS server in the same farm (or if profile migration occurs), the credential cannot be decrypted — DPAPI uses a master key from the user's local profile, which does not roam correctly. The result: the user is silently re-prompted to sign in with Google on each new server session, or the credential read fails silently and the app shows as unauthenticated.

**Why it happens:**
DPAPI documentation states it is "user-scoped" (only the creating user can decrypt), but the "user" identity is tied to the login session's key material, which does not correctly roam across machines even when the Windows profile roams. This is a known limitation that affects all apps using DPAPI for credential storage in multi-server RDS farms.

**How to avoid:**
- Accept that in RDS environments, users may need to re-authorize after session migration. Document this as expected behavior.
- Provide a clear "Re-authorize Gmail" button in the tray menu for when this occurs.
- Do not fall back to storing the refresh token in plaintext on disk — the risk of exposing Gmail access to other users sharing the server outweighs the re-auth friction.
- If the customer environment uses a dedicated per-user RDS session host (common for smaller deployments), this pitfall is moot — the user always lands on the same server.
- Consider Azure Key Vault or a similar server-side credential store for enterprise deployments (defer to a later milestone; note the architecture decision).

**Warning signs:**
- Users in RDS farms report needing to sign in to Gmail every few sessions
- `wincred` read returns "The specified credential does not exist" despite successful prior authorization
- Profile event log shows roaming profile sync errors around the time of sign-in failures

**Phase to address:** Phase 2 — OAuth implementation. Document the RDS roaming profile limitation in the user-facing docs and in the installer notes. Test on a two-host RDS farm if possible.

---

### Pitfall 7: Wails v2 system tray — hidden window on startup and logoff handling

**What goes wrong:**
Wails v2 (stable) has documented issues with the system-tray-as-primary-UI pattern:

1. **Hidden window on launch**: Starting the app with `WindowStartState: options.WindowStartStateMinimised` or `HideWindowOnClose: true` causes a brief flash of a blank window before it hides, or in some builds, the window stays visible and non-interactive. This is visible to users and feels like a crash.

2. **WM_QUERYENDSESSION not handled**: Wails v2 does not expose a hook for Windows logoff/shutdown (the `WM_QUERYENDSESSION` / `WM_ENDSESSION` messages). If go-mapi has a MAPI draft in-flight when the user logs off, the Go goroutine is killed without completing, the JSON file remains in `%TEMP%\go-mapi\`, and the draft is never created. On next login, the watcher will find the stale JSON and re-attempt — which is the correct behavior, but only if the app handles startup correctly.

3. **Multiple instances**: Nothing in Wails v2 prevents a second go-mapi instance from starting. Two instances watching the same directory will both try to process the same JSON file, creating duplicate drafts. Windows does not enforce single-instance by default.

4. **Wails v3 alpha consideration**: Wails v3 offers better tray support and proper hidden-window handling, but as of 2025 it is in alpha. The tray hidden-window issue was specifically reported in v3 alpha 22 and is not yet resolved. Using v3 for production v3.0 carries alpha-stability risk.

**Why it happens:**
Wails wraps the WebView2 window inside a Win32 window. System tray apps traditionally use a `HWND_MESSAGE`-only window with no visible surface — Wails always creates a visible window, then tries to hide it. The race between window creation, WebView2 initialization, and the hide call is the source of the flash.

**How to avoid:**
- Use a named mutex (`CreateMutex` via `golang.org/x/sys/windows`) at app startup to enforce single-instance. If the mutex already exists, bring the existing instance's window to front and exit.
- For logoff handling, register a `WM_QUERYENDSESSION` handler using a hidden message-only window (`CreateWindowEx` with `HWND_MESSAGE`) in a separate goroutine, independent of Wails. On receipt, signal the watcher goroutine to stop gracefully.
- Use `HideWindowOnClose: true` combined with an explicit `WindowHide()` call immediately after `wails.Run()` starts (from the `OnStartup` hook) rather than relying on startup state flags.
- Stick with Wails v2 for v3.0 unless v3 reaches a stable release milestone before implementation begins. Monitor [wailsapp/wails releases](https://github.com/wailsapp/wails/releases).

**Warning signs:**
- Users report a blank white window appearing at login, then disappearing
- Two go-mapi icons appear in the system tray after a crash-restart cycle
- Gmail shows duplicate drafts for a single MAPI send event

**Phase to address:** Phase 1 — Wails shell. Implement named mutex and logoff handler as foundational scaffolding, not afterthoughts.

---

### Pitfall 8: Self-update on Windows — cannot replace a running EXE

**What goes wrong:**
Windows locks running executables — you cannot overwrite `go-mapi.exe` while it is running. Any self-update approach that downloads a new binary and tries to `os.Rename()` or `os.WriteFile()` over the current executable will fail with "The process cannot access the file because it is being used by another process." This is the fundamental blocker for self-updating desktop apps on Windows. Additionally, if the update process is interrupted (network drop, power loss, user kill), the app directory may contain a partially-downloaded binary with the same name as the installed binary, causing the next launch to fail silently or crash.

**Why it happens:**
Wails has no built-in update mechanism. The project documentation suggests `minio/selfupdate` or `creativeprojects/go-selfupdate`, both of which use the sidecar/rename-on-next-launch pattern — but this requires the app to exit before the replacement can occur. For a tray app that users never explicitly close, this means update applies only on the next user-initiated restart or logon.

**How to avoid:**
- Use the "rename then copy" pattern: download new binary as `go-mapi-new.exe` in the install directory, verify signature, then write a small launcher/updater exe that exits the main app, waits for its process to terminate, renames the files, and relaunches. The `go-selfupdate` library has primitives for this.
- Require the update to take effect at next login, not immediately. Show a notification: "Update downloaded — will apply at next login." This is acceptable for go-mapi's use pattern.
- Never update if the installer directory requires admin rights (it does — it's under Program Files). The self-update attempt will fail with UAC prompt or access denied. For installer-based updates, re-running the installer is the correct path; document this clearly and provide a "Check for Updates" tray menu item that opens the download URL rather than attempting in-process update.
- Verify the downloaded binary signature before replacing anything. Go's `crypto/sha256` plus a published checksum file is the minimum viable approach.

**Warning signs:**
- "go-mapi.exe: Access is denied" error in update logs
- App silently runs the old version after the update download reports success
- Partially downloaded binary in install directory causes launch failures

**Phase to address:** Phase 5 — Distribution and autoupdate. Design update delivery as "installer re-run" rather than in-process replacement for the first release.

---

### Pitfall 9: Clean-break migration — orphaned registry entries and native messaging manifests

**What goes wrong:**
Users upgrading from v2.x to v3.0 are instructed to uninstall v2.x first. In practice, a significant fraction will not, or will skip the uninstall step when prompted. The result:

1. **Orphaned native messaging manifests**: v2.x installs manifests at `%APPDATA%\Google\Chrome\NativeMessagingHosts\com.gomapi.host.json` and `%APPDATA%\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host.json`. Chrome and Edge attempt to launch the old native host on every extension connect, even after the extension is uninstalled. If the old host binary is missing but the manifest remains, Chrome logs errors and may retry launching a non-existent process.

2. **MAPI handler collision**: The v2.x installer registered `go-mapi` as the default MAPI handler under `HKLM:\SOFTWARE\Clients\Mail\go-mapi`. If Outlook is installed on the same machine, it registers under a different key and wins the `(Default)` value. If a user has both installed and one uninstalls incorrectly, the `(Default)` can point to a deleted key, causing all MAPI sends to silently fail with no mail client found.

3. **Watcher temp directory state**: If v2.x left unprocessed JSON files in `%TEMP%\go-mapi\`, the v3.0 app's watcher will pick them up on first launch. This is usually the correct behavior, but if the old files are malformed or from an incompatible protocol version, it will generate errors.

**Why it happens:**
The v3.0 installer is a clean break — it does not know about the v2.x installation state. Users who skip uninstall leave behind registry and file artifacts that the v3.0 installer does not remove.

**How to avoid:**
- The v3.0 installer should detect and clean v2.x artifacts: check for the existence of native messaging manifest paths and remove them. Check for `%APPDATA%\Google\Chrome\NativeMessagingHosts\com.gomapi.host.json` and delete it.
- Emit a clear prompt during installation: "go-mapi v2.x was detected. Its browser extension components have been removed. If you had the extension installed in Chrome or Edge, you can uninstall it from your browser's extension page."
- Add a protocol version field check at the watcher level — if a JSON file has an incompatible version, move it to errors/ rather than attempting to process it.
- Test the "install without prior uninstall" path explicitly before release.

**Warning signs:**
- Users report "Send to mail recipient" does nothing after installing v3.0 (MAPI handler not registered or colliding)
- Chrome or Edge shows native host errors even though the extension is uninstalled
- `%TEMP%\go-mapi\errors\` fills with files on first v3.0 launch

**Phase to address:** Phase 4 — Installer build. The v3.0 installer must include a v2.x artifact cleanup step. Test clean-break on a VM with v2.x installed.

---

### Pitfall 10: SmartScreen reputation — new binary, no reputation, users see alarming warning

**What goes wrong:**
Every newly released go-mapi.exe binary starts with zero SmartScreen reputation. When a user downloads and runs the installer, Windows Defender SmartScreen shows: "Windows protected your PC — Microsoft Defender SmartScreen prevented an unrecognized app from starting." Non-technical users (the primary audience) will click "Don't run" and give up. This warning appears regardless of whether the binary is signed with an OV certificate from SignPath.

As of August 2024, Microsoft removed EV Code Signing OIDs from root certificates, meaning EV certificates no longer bypass SmartScreen automatically. OV certificates (which SignPath Foundation provides) require reputation to be built over time through sufficient download volume.

**Why it happens:**
SmartScreen reputation is per-binary-hash. Each new release starts at zero. The only paths to immediate reputation are: (a) enough downloads of the exact binary within Microsoft's telemetry window (not viable for a small FOSS tool), or (b) submit the binary to Microsoft's Malware Protection Center for manual review.

**How to avoid:**
- Sign every release binary (installer and exe) via SignPath Foundation. While OV signing doesn't bypass SmartScreen, unsigned binaries get a far more severe warning ("This app may harm your device"). Signed binaries at least show the publisher name.
- Submit each new release to [Microsoft's intelligence submission portal](https://www.microsoft.com/en-us/wdsi/filesubmission) for manual review before publishing the download link. For a clearly benign FOSS tool, approval typically takes 1–3 business days.
- Add explicit SmartScreen bypass instructions to the download page: "If Windows shows a security warning, click 'More info' → 'Run anyway'. This is expected for new releases." Include a screenshot.
- Include SHA256 checksums for all release artifacts so security-conscious users can verify before bypassing.
- Over time, reputation builds as more users download and run without triggering AV alerts. By v3.1+, the warning should be rare for the same signing certificate.

**Warning signs:**
- Users report the installer won't run or that Windows blocked it
- Downloading via direct link triggers Chrome's "This file may be dangerous" warning (separate from SmartScreen)
- VirusTotal shows 0/70 detections but SmartScreen still blocks (this is expected — SmartScreen uses its own telemetry, not AV signatures)

**Phase to address:** Phase 4 — Installer build and Phase 5 — Distribution. Budget time for Microsoft Malware Protection Center submission as part of the release checklist.

---

### Pitfall 11: Wails v2 ecosystem maturity — Go version sensitivity and upstream responsiveness

**What goes wrong:**
Wails v2 has known build issues with specific Go versions:
- GOARCH=386 (32-bit) Windows builds crash on startup — WebView2 crashes immediately.
- Cross-compilation from macOS to Windows broke between v2.9.2 and v2.10.1.
- Dev mode (`wails dev`) had console log spam and connection issues introduced in v2.10.

The upstream project is active but has a significant issue backlog. Security fixes are not always backported promptly. The project is simultaneously working toward v3 (alpha), which means v2 may receive reduced attention over time.

**Why it happens:**
Wails is a smaller open-source project without a corporate backing team. Its Windows support depends on WebView2 behavior, which itself changes with Edge updates (Evergreen runtime). The intersection of Go version × WebView2 version × Windows version creates a wide compatibility matrix that a small maintainer team cannot fully test.

**How to avoid:**
- Pin the Go version in CI (`.go-version` file or `go.toolchain` in `go.mod`). Test upgrades explicitly before upgrading.
- Build for 64-bit Windows only (GOARCH=amd64). The 32-bit build bug is unlikely to be fixed soon; 32-bit Windows is not a supported target anyway.
- Follow Wails releases carefully. Subscribe to the GitHub release feed. Do not upgrade Wails mid-milestone without testing.
- For Wails v3: do not adopt until it reaches a stable (non-alpha) release with at least one production-proven tray-app cycle.

**Warning signs:**
- `wails build` panics with "unsupported version: 2" after a Go upgrade (actual reported issue)
- WebView2 window appears blank after a WebView2 runtime update (Evergreen auto-updated overnight)
- CI builds pass but Windows runtime shows different behavior (dev vs release mode divergence)

**Phase to address:** Phase 1 — Wails shell. Lock Go version, test 64-bit only, verify tray behavior on release build (not dev mode) before proceeding.

---

### Pitfall 12: Gmail API draft quota — not a per-project quota, but concurrent request handling matters

**What goes wrong:**
The Gmail API has two simultaneous rate limits: a per-project limit (1 billion quota units/day, virtually unlimited) and a per-user limit (250 quota units/user/second as a moving average). Creating a draft costs roughly 10 quota units. Under normal use, no single user will approach limits. However, in RDS environments where 30 users might all click "Send to Mail Recipient" at once (e.g., a bulk mailing workflow), 30 simultaneous `drafts.create` calls go out. Because each is tied to a different Google account (a different user's OAuth token), the per-user limits are independent — this is safe. The risk is a different failure: the current Gmail client has no retry on transient 429 or 503 responses and no timeout, as documented in CONCERNS.md. A single failed call surfaces as a lost draft with no recovery path.

The shared-IP risk on RDS is lower than feared: Google's rate limits are per-user-account, not per-IP. Multiple users on the same RDS server hitting the Gmail API simultaneously will not interfere with each other's per-user quotas.

**How to avoid:**
- Add retry logic (3 attempts, exponential backoff) for 429 and 5xx responses from the Gmail API. This is already flagged in CONCERNS.md as a fragile area; it becomes critical under RDS load.
- Add a configurable timeout (30 seconds) to the Go HTTP client used for Gmail API calls. This is also flagged in CONCERNS.md.
- Log the request ID from Gmail API responses to aid debugging when drafts fail.
- Per-project quota overrides are available from Google if needed — but at 30 users × ~10 drafts/day, total usage is ~3,000 quota units/day, which is nowhere near the 1 billion limit.

**Warning signs:**
- Go host logs show `Post "https://gmail.googleapis.com/...": context deadline exceeded` (confirms missing timeout)
- Users report drafts occasionally not appearing despite no visible error
- During load spike, multiple users see "draft-error" simultaneously

**Phase to address:** Phase 3 — Queue and action implementation. Fix the Gmail client timeout and retry before any multi-user testing.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Trust "WebView2 shares Edge runtime" marketing claim without measuring | No benchmark work needed in Phase 1 | RDS RAM budget exceeded; architecture rework required after commitment | Never — measure in Phase 1 prototype |
| Use Evergreen bootstrapper without silent-install timing fix | Small installer size | Silent install failure on servers without CDN access; blank window on first launch | Only for consumer (non-RDS) builds; RDS needs offline installer |
| Skip Google OAuth verification until after launch | Faster time to public release | Hit 100-user cap within days of first RDS customer; users blocked | Never — submit for verification at Phase 2 start |
| Store refresh token in plaintext file | No DPAPI/keyring dependency | Token readable by any process running as the same user; credential theft risk | Never |
| Allow multiple instances of go-mapi | No mutex code needed | Duplicate drafts created per MAPI event; user sees double entries | Never — single-instance guard is two lines |
| Self-update via in-process binary replace | Simpler update code | Fails on Windows (EXE locked); partial downloads corrupt install | Never on Windows |
| Ship without SmartScreen submission | Faster release | Non-technical users cannot install; tool effectively unusable by primary audience | Acceptable for developer preview only |
| Adopt Wails v3 alpha for better tray support | Better hidden-window behavior | Alpha instability; known tray bugs in v3; production risk | Only after v3 reaches stable release |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| WebView2 process model | Assume processes are shared across RDS user sessions | Each session gets its own process group; no cross-session sharing is possible |
| WebView2 installer | Use bootstrapper with `/silent /install` and trust exit code | Bootstrapper exits before install completes; poll for completion or bundle standalone installer |
| Google OAuth loopback | Use `http://localhost` as redirect URI | Use `http://127.0.0.1` (IP not hostname); `localhost` can be blocked by firewalls |
| Google OAuth consent | Treat 100-user cap as a future problem | The cap is lifetime and non-resettable; submit verification at Phase 2 start |
| Gmail API 401 | Log error and show generic "failed" message | Detect 401 specifically, clear token, trigger re-auth flow |
| Windows Credential Manager | Expect DPAPI-encrypted credentials to roam in RDS | DPAPI is session-bound; document re-auth requirement for multi-server RDS farms |
| Self-update | Attempt to overwrite running go-mapi.exe | Windows locks running EXEs; use rename-on-relaunch or re-run installer pattern |
| MAPI registry | Assume only go-mapi touches `HKLM:\SOFTWARE\Clients\Mail` | Outlook and Thunderbird also register here; v3.0 installer must not clobber existing default |
| Native messaging manifests | Assume v3.0 installer starts clean | v2.x manifests in `%APPDATA%\Google\Chrome\NativeMessagingHosts\` remain; v3.0 installer must remove them |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| WebView2 window always initialized on launch | 80–150 MB RAM per session regardless of use | Lazy-init WebView2 only on first window open; keep Go binary running in tray with no WebView2 | At ~15 concurrent RDS users on a 8 GB server |
| Gmail HTTP client with no timeout | Draft creation goroutine hangs indefinitely on network stall | Add 30s timeout to `http.Client`; already flagged in CONCERNS.md | On first Gmail API instability event |
| Watcher debounce processes files from prior v2.x session | Burst of old JSON files processed on v3.0 first launch | Version-stamp JSON files; reject files with incompatible version field | On every v2.x → v3.0 migration |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Storing refresh token in `%APPDATA%` plaintext file | Any user-level process can read the Gmail access token | Use Windows Credential Manager (wincred); never write token to disk directly |
| Writing email body content to `native-host.log` | Log on shared RDS server is readable by other local users | Log only email ID hash and action; never log subject, body, or recipient |
| No single-instance guard | Second instance processes same JSON file; two drafts created | Named mutex at startup; exit if mutex already held |
| Watch directory `%TEMP%\go-mapi\` world-readable on RDS | Other users on the same server can read email JSON | Set DACL on watch directory at installer time to restrict to installing user only |
| OAuth state parameter not validated in loopback callback | CSRF attack possible on the loopback redirect | Generate cryptographically random state parameter; validate on callback |

---

## "Looks Done But Isn't" Checklist

- [ ] **WebView2 RAM**: Measured per-session RAM on Windows Server with 5+ simultaneous users — not just on developer workstation
- [ ] **WebView2 runtime offline**: Tested installer on a clean Windows Server image with no Edge and no internet access
- [ ] **OAuth consent verification**: Submitted to Google for sensitive scope verification before public release
- [ ] **Firewall rule**: Installer creates Windows Firewall rule for go-mapi.exe loopback inbound connections
- [ ] **Single instance**: Named mutex prevents second instance; test by launching go-mapi.exe twice
- [ ] **Logoff handler**: MAPI draft in-flight at logoff is handled gracefully — JSON file remains for next-session processing
- [ ] **Token revocation**: Test flow where user revokes access from Google Account — app prompts re-auth, does not loop-fail
- [ ] **SmartScreen submission**: Binary submitted to Microsoft WDSI before publishing download link
- [ ] **v2.x artifact cleanup**: v3.0 installer removes native messaging manifests from `%APPDATA%\Google\Chrome\NativeMessagingHosts\` and `%APPDATA%\Microsoft\Edge\NativeMessagingHosts\`
- [ ] **MAPI handler**: v3.0 installer does not overwrite `HKLM:\SOFTWARE\Clients\Mail\(Default)` if Outlook is present; go-mapi registers itself without clobbering the existing default
- [ ] **Release build tray behavior**: System tray tested on `wails build` output, not `wails dev` — dev mode has different window lifecycle behavior

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| RDS RAM over budget | HIGH | Implement lazy WebView2 init; if still over, evaluate native Win32 queue dialog for RDS tier |
| WebView2 not installed on server | MEDIUM | Publish a second "offline installer" bundle that includes WebView2 standalone; document IT deployment instructions |
| OAuth 100-user cap hit | HIGH | Create a new GCP project with a new OAuth client ID; existing users must re-authorize; submit new project for verification immediately |
| Refresh token invalidated silently | LOW | Re-auth flow triggered on 401; user re-authorizes in ~30 seconds |
| SmartScreen blocks installation | MEDIUM | Submit to Microsoft WDSI (1–3 days); publish bypass instructions on download page in the interim |
| Orphaned v2.x manifests break Chrome | MEDIUM | Manually delete `%APPDATA%\Google\Chrome\NativeMessagingHosts\com.gomapi.host.json`; add to v3.0 installer cleanup step |
| Self-update corrupts install directory | HIGH | Re-run full installer from download URL; installer must detect corrupt state and overwrite |
| Duplicate drafts from two instances | MEDIUM | Named mutex prevents recurrence; duplicates must be manually deleted from Gmail by user |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| WebView2 RAM budget for RDS | Phase 1 — Wails shell prototype | Measure RSS for 5-user multi-session on Windows Server before proceeding |
| WebView2 offline install failure | Phase 4 — Installer build | Test on clean Windows Server VM with no Edge and no internet |
| OAuth 100-user cap | Phase 2 — OAuth (start of phase) | GCP project submitted for verification; test-user allowlist in place for beta |
| OAuth loopback port/firewall | Phase 2 — OAuth | End-to-end OAuth test on Windows Server with default firewall; firewall rule in installer |
| Refresh token silent invalidation | Phase 2 — OAuth | Test: revoke token in Google Account → verify app prompts re-auth within 60 seconds |
| DPAPI/RDS credential scope | Phase 2 — OAuth | Documented in user-facing notes; test on two-server RDS farm if available |
| Wails tray window lifecycle | Phase 1 — Wails shell prototype | Named mutex test; logoff test on Windows Server |
| Self-update Windows EXE lock | Phase 5 — Distribution | Self-update design review; "re-run installer" approach confirmed |
| v2.x artifact migration | Phase 4 — Installer build | Install v2.x on VM, run v3.0 installer, verify manifests removed and MAPI handler correct |
| SmartScreen reputation | Phase 4/5 — Distribution | WDSI submission completed; bypass instructions on download page |
| Wails ecosystem maturity | Phase 1 — Wails shell | Go version pinned; 64-bit only; release build tray behavior verified |
| Gmail API retry/timeout | Phase 3 — Queue and actions | `http.Client` timeout set; retry on 429/5xx verified in integration test |

---

## Sources

- [WebView2 process model — Microsoft Learn](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/process-model) — HIGH confidence; official docs
- [WebView2 performance best practices — Microsoft Learn](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/performance) — HIGH confidence; official docs, updated Jan 2026
- [WebView2 distribution modes — Microsoft Learn](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution) — HIGH confidence; official docs
- [WebView2 Evergreen bootstrapper silent install exit bug — GitHub](https://github.com/MicrosoftEdge/WebView2Feedback/issues/1349) — HIGH confidence; confirmed issue
- [WebView2 silent install returns error code — GitHub](https://github.com/MicrosoftEdge/WebView2Feedback/issues/555) — MEDIUM confidence; older report, may be partially fixed
- [Google OAuth for native apps — developers.google.com](https://developers.google.com/identity/protocols/oauth2/native-app) — HIGH confidence; official
- [Google OAuth loopback IP migration guide — developers.google.com](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration) — HIGH confidence; official
- [Google OAuth unverified apps / 100-user cap — support.google.com](https://support.google.com/cloud/answer/7454865) — HIGH confidence; official
- [Google OAuth refresh token expiry conditions — developers.google.com](https://developers.google.com/identity/protocols/oauth2) — HIGH confidence; official
- [Gmail API usage limits — developers.google.com](https://developers.google.com/workspace/gmail/api/reference/quota) — HIGH confidence; official
- [Wails v2 known issues — wailsapp/wails GitHub](https://github.com/wailsapp/wails/issues) — MEDIUM confidence; issue tracker snapshot, may change
- [Wails v3 hidden window bug — GitHub issue #4498](https://github.com/wailsapp/wails/issues/4498) — MEDIUM confidence; specific alpha issue
- [Wails self-update discussion — GitHub #2720](https://github.com/wailsapp/wails/discussions/2720) — MEDIUM confidence; community discussion
- [creativeprojects/go-selfupdate — pkg.go.dev](https://pkg.go.dev/github.com/creativeprojects/go-selfupdate) — HIGH confidence; library docs
- [Authenticode in 2024 — textslashplain.com](https://textslashplain.com/2024/05/22/authenticode-in-2024/) — HIGH confidence; authoritative Windows security blog
- [SignPath Foundation — signpath.org](https://signpath.org/) — HIGH confidence; official
- [MAPI stub registry settings — Microsoft Learn](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/windowsmapi/mapi32-dll-stub-registry-settings) — HIGH confidence; official
- [Thunderbird MAPI registration issues — Mozilla Bugzilla](https://bugzilla.mozilla.org/show_bug.cgi?id=1530820) — MEDIUM confidence; historical bug reports
- [WebView2 UDF multi-instance issue — GitHub #4751](https://github.com/MicrosoftEdge/WebView2Feedback/issues/4751) — MEDIUM confidence; specific version issue
- Existing codebase CONCERNS.md (2026-04-10) — HIGH confidence; direct audit of current code

---
*Pitfalls research for: go-mapi v3.0 Wails pivot (Wails + WebView2 + Google OAuth desktop flow + RDS deployment + signed installer + clean-break migration)*
*Researched: 2026-04-12*
