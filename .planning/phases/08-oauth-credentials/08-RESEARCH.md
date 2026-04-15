# Phase 8: OAuth + Credentials - Research

**Researched:** 2026-04-15
**Domain:** Google OAuth 2.0 desktop flow (PKCE loopback) in Go + Windows Credential Manager + Wails v2 runtime events
**Confidence:** HIGH (pattern verified against official Google docs, RFC 8252, `golang.org/x/oauth2` v0.36.0 exported API, and Phase 7 code already in tree)

## Summary

Phase 8 wires a native-desktop Google OAuth flow into the existing Phase 7 Wails shell (`src/app/`). CONTEXT.md already locks 19 implementation decisions — this research fills in the mechanical details the planner needs to write tasks: exact PKCE helper names in `golang.org/x/oauth2`, keyring backend config, loopback listener lifecycle, URL-opener choice, userinfo/revoke endpoints, build-time `-ldflags` pattern, and Wails v2 event threading.

The primary reference remains `.planning/research/ARCHITECTURE.md §5`; this doc **extends, not duplicates** — citing §5 when a subsection is the authoritative source. One resolved conflict: CONTEXT.md D-11 locks `github.com/99designs/keyring`, which contradicts `.planning/research/STACK.md` and `SUMMARY.md §"Minor library conflict"` (those recommend `zalando/go-keyring` as simpler). **CONTEXT.md wins** — the planner proceeds with 99designs/keyring. The conflict is noted in the Open Questions section; if keyring configuration friction on Windows becomes a task-level blocker, the planner should escalate.

**Primary recommendation:** Implement `src/app/auth.go` using `golang.org/x/oauth2@v0.36.0` for the OAuth config + PKCE helpers, `github.com/99designs/keyring@v1.2.2` with `AllowedBackends: []BackendType{WinCredBackend}`, a per-sign-in `net/http.Server` on `127.0.0.1:0` with 5-minute `context.WithTimeout`, and `exec.Command("rundll32", "url.dll,FileProtocolHandler", authURL)` to open the system browser.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**GCP verification**
- D-01: Ship v3.0 unverified (100 test-user cap); file verification on Phase 8 day 1 — do not block release on Google's 4–8 week queue.
- D-02: Before first-run browser launch, show one-time in-app pre-auth modal explaining Google's "Advanced → Go to go-mapi (unsafe)" path. Dismissible "Continue to Google" CTA; stored as seen so it never re-shows.

**Sign-in UX placement**
- D-03: First run opens main window to a welcome/sign-in screen; no queue list visible until signed in. Single prominent "Sign in with Google" button.
- D-04: If user closes sign-in window without signing in, app stays in tray with error-icon variant; watcher keeps queueing; draft actions disabled.

**Re-auth (`invalid_grant`) UX**
- D-05: Three concurrent signals — (a) tray flips to error icon, (b) if window open, red top banner "Sign-in expired — click to restore" with CTA, (c) Windows toast (stub via `x/sys/windows` if trivial, else defer to Phase 9). **Never block with modal.** Queue keeps collecting.
- D-06: Re-auth flow is loopback+PKCE again, skip the pre-auth explainer (already seen). Success dismisses banner, restores tray, resumes.

**Draft-button design contract (for Phase 9)**
- D-07: No token → buttons disabled with tooltip "Sign in first". Sign-in banner is the only CTA. Phase 8 ships `GetAuthStatus()` binding Phase 9 will toggle on.

**Client credential embedding**
- D-08: `client_id` + `client_secret` embedded via build-time `-ldflags` injection (empty string `var` in source, CI injects from GitHub secrets `GOMAPI_OAUTH_CLIENT_ID` / `GOMAPI_OAUTH_CLIENT_SECRET`).
- D-09: Local dev reads same env var names at `wails dev` time; falls back to `-ldflags` value for release.
- D-10: Missing credentials at runtime = fatal startup error with clear log message.

**Keyring + storage**
- D-11: Service `go-mapi`; key `oauth-tokens`. JSON payload `{access_token, refresh_token, expiry (RFC3339), token_type}`. Single entry, no multi-account.
- D-12: Keyring open-failure = hard fail at sign-in with clear UI error. **Do NOT fall back to encrypted file** (ARCH §Anti-Pattern 4). Sign-out when no entry = no-op.

**Token refresh**
- D-13: Proactive (`expiry < now + 5min`) + reactive (401 retry once). Serialized via mutex on App struct's auth manager. Matches ARCH §5 exactly.
- D-14: `GmailClient` stays stateless — receives token per call. All refresh logic in `auth.go`.

**Sign-out**
- D-15: Control in main window header (top-right, near account display). Best-effort `POST /revoke` (5s timeout) → clear keyring unconditionally → emit `auth-changed {authenticated:false}` → return to welcome screen. No confirmation modal.
- D-16: Sign-out does NOT quit app. Watcher runs; tray stays.

**Account display**
- D-17: After sign-in, fetch `https://www.googleapis.com/oauth2/v3/userinfo`; cache `email`, `name` **in memory only** (App struct field). Re-fetched each app start. Never persisted (QUAL-03).

**File layout + bindings**
- D-18: `auth.go` lives in `src/app/`, NOT `internal/mapi/`. Imports `internal/mapi` only for `MailMessage` if needed.
- D-19: Wails bindings: `GetAuthStatus() AuthStatus`, `SignIn() error`, `SignOut() error`. Event: `auth-changed` with `AuthStatus` payload.

### Claude's Discretion
- Exact UI copy (welcome, pre-auth modal, re-auth banner, sign-out button) — English for FOSS project.
- Loopback listener timeout (2–5 min window); Cancel button stops listener.
- URL opener choice: `rundll32 url.dll,FileProtocolHandler` vs `ShellExecuteW` — planner picks stdlib-clean option.
- Pre-auth modal treatment (plain vs screenshot-embedded).
- Refresh mutex placement (per-App-instance since App is per-process).
- OAuth event logging level — align with Phase 7 `%APPDATA%\go-mapi\app.log`; never log token contents.
- Trivial `x/sys/windows` toast stub for re-auth if a few lines; otherwise punt to Phase 9.

### Deferred Ideas (OUT OF SCOPE)
- WinRT toast infrastructure (Phase 9)
- Per-email draft-action buttons (Phase 9; Phase 8 only ships the `GetAuthStatus()` binding)
- Multi-account / account switcher (deferred; PROJECT.md Out of Scope)
- Per-action mode (Manual/Auto-draft/Auto-send) — Phase 9
- Pause-watching tray menu item — Phase 9
- Installer + CI credential injection plumbing — Phase 10 (Phase 8 proves pattern works in local `wails build`)
- Scope-incremental consent — both scopes at initial consent
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| AUTH-01 | First-run prompts Google OAuth desktop flow (loopback `127.0.0.1` ephemeral port, PKCE S256) | §Loopback Listener Pattern, §PKCE S256 Exact Spec, §x/oauth2 API |
| AUTH-02 | System browser (not embedded webview) for consent | §URL Opener on Windows |
| AUTH-03 | Refresh token stored via `99designs/keyring` (Windows Credential Manager) — no plaintext on disk | §99designs/keyring Windows Specifics |
| AUTH-04 | Access token refreshes transparently on 401 | §Token Refresh Mechanics (ARCH §5 extended) |
| AUTH-05 | `invalid_grant` on refresh triggers re-auth UX (no retry loop) | §Token Refresh Mechanics, §Error Classification |
| AUTH-06 | New GCP desktop client; verification filed Phase 8 day 1 (sensitive scopes `gmail.compose`, `gmail.send`) | CONTEXT D-01 (non-code, owner task) |
| AUTH-07 | Sign-out control clears stored token | §Revoke Endpoint |
| QUAL-03 | No telemetry / no content retention / no network calls outside Gmail API + GitHub Releases | §Userinfo Endpoint (in-memory only), §Logging Posture |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `golang.org/x/oauth2` | v0.36.0 (2026-02-11) | OAuth2 config + token exchange + PKCE helpers + refresh | Official Google-maintained Go OAuth2 package; built-in `GenerateVerifier`/`S256ChallengeOption`/`VerifierOption` — no hand-rolled PKCE needed [VERIFIED: proxy.golang.org list for golang.org/x/oauth2 returns v0.36.0 as latest; pkg.go.dev exports include GenerateVerifier, S256ChallengeOption, VerifierOption] |
| `github.com/99designs/keyring` | v1.2.2 (latest on proxy) | Windows Credential Manager backend | Locked by CONTEXT D-11 [VERIFIED: proxy.golang.org list for github.com/99designs/keyring returns v1.2.2 as latest] |

### Supporting (stdlib only — no extra deps)
| Package | Purpose | When to Use |
|---------|---------|-------------|
| `net/http` + `net` | Loopback listener on `127.0.0.1:0`, single-shot callback handler | In `SignIn()` flow |
| `crypto/rand` | 32-byte state parameter (CSRF defence) | Every `SignIn()` call — unique per flow |
| `context` | Per-sign-in cancellation + timeout | Wraps loopback listener shutdown |
| `os/exec` | Launch system browser via `rundll32 url.dll,FileProtocolHandler` | `openBrowser(authURL)` helper |
| `encoding/json` | Marshal/unmarshal keyring payload + userinfo + revoke bodies | Keyring item + Google endpoints |
| `sync` | `sync.Mutex` on AuthManager for refresh serialization (D-13) | `AuthManager` struct field |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `99designs/keyring` | `zalando/go-keyring` v0.2.8 | Simpler 3-function API; SUMMARY.md flagged as "minor library conflict" with ARCH.md. CONTEXT D-11 explicitly picks 99designs. If keyring-init friction appears, escalate — don't swap without user confirmation. |
| Hand-rolled OAuth HTTP | `x/oauth2` | Hand-rolled = re-implementing token endpoint, refresh, PKCE. No upside for a Google-standard flow. |
| `rundll32 url.dll,FileProtocolHandler` | `golang.org/x/sys/windows.ShellExecute` / `github.com/pkg/browser` | `pkg/browser` is already an indirect dep (Wails pulls it). But `exec.Command("rundll32", ...)` is stdlib-only, zero deps, matches FEATURES.md §4 recommendation, and respects the user's default browser. Planner's discretion per CONTEXT. |
| Fixed loopback port | Ephemeral `:0` | Fixed ports collide in RDS (PITFALLS §4); ephemeral is mandatory. Google allows any port for `127.0.0.1` redirect URIs [CITED: developers.google.com/identity/protocols/oauth2/resources/loopback-migration]. |

**Installation (verify before committing):**
```bash
# From src/app/ (Wails workspace)
go get golang.org/x/oauth2@v0.36.0
go get github.com/99designs/keyring@v1.2.2

# Verify versions
npm view is N/A — these are Go modules. Use:
go list -m golang.org/x/oauth2     # expect v0.36.0
go list -m github.com/99designs/keyring   # expect v1.2.2
```

**Version provenance:** Latest versions confirmed via `https://proxy.golang.org/{module}/@v/list` on 2026-04-15 [VERIFIED]. x/oauth2 v0.36.0 published 2026-02-11 per proxy `.info` endpoint.

## Architecture Patterns

> This section extends `.planning/research/ARCHITECTURE.md §5`. Do not duplicate the flow diagram there.

### Project Structure (delta over Phase 7)

```
src/app/
├── main.go              # existing — Phase 7
├── app.go               # existing — App struct; Phase 8 ADDS fields: auth *AuthManager, userEmail/userName strings
├── auth.go              # NEW — AuthManager, OAuthTokens type, SignIn/SignOut/GetAuthStatus
├── auth_test.go         # NEW — PKCE verifier length, state generation, token JSON round-trip
├── auth_credentials.go  # NEW — package-level var oauthClientID, oauthClientSecret (ldflags injection targets)
├── ...                  # existing Phase 7 files unchanged
```

`auth.go` lives in `package main` (not a subpackage) — this matches Phase 7's flat `src/app/` layout (all files are `package main`; cf. `app.go`, `logging.go`, `tray.go`). Per CONTEXT D-18, do not move to `internal/mapi/`.

### Pattern 1: AuthManager struct (extends ARCH §5)

```go
// Source: extends .planning/research/ARCHITECTURE.md §5
// Confidence: HIGH — direct port of ARCH §5 snippet with mutex per D-13

type AuthManager struct {
    ring    keyring.Keyring
    tokens  *OAuthTokens      // nil when signed out
    email   string            // D-17 in-memory only
    name    string            // D-17 in-memory only
    refresh sync.Mutex        // D-13 serialize refreshes
    cfg     *oauth2.Config    // built once from embedded client_id/secret
}

type OAuthTokens struct {
    AccessToken  string    `json:"access_token"`
    RefreshToken string    `json:"refresh_token"`
    TokenType    string    `json:"token_type"`  // D-11 adds token_type
    Expiry       time.Time `json:"expiry"`
}

type AuthStatus struct {
    Authenticated bool   `json:"authenticated"`
    Email         string `json:"email,omitempty"`
    Name          string `json:"name,omitempty"`
}
```

### Pattern 2: Wails v2 runtime events from Go [VERIFIED: src/app/app.go line 7 `wruntime "github.com/wailsapp/wails/v2/pkg/runtime"`]

```go
// Source: src/app/app.go already imports wruntime; Phase 7 established ctx handoff pattern
import wruntime "github.com/wailsapp/wails/v2/pkg/runtime"

// In App.startup(ctx), ctx is cached on a.ctx (line 36-37 of app.go).
// Phase 8 emits:
wruntime.EventsEmit(a.ctx, "auth-changed", AuthStatus{Authenticated: true, Email: "..."})
```

The `ctx` captured in `App.startup(ctx context.Context)` (Phase 7 pattern, line 36 of app.go) is the one to pass to `EventsEmit`. No new context plumbing needed — `AuthManager.SignIn/SignOut` take `*App` as receiver dependency (or accept `ctx` as first arg) and call `wruntime.EventsEmit(a.ctx, ...)`.

### Pattern 3: OAuth Config construction

```go
// Source: pkg.go.dev/golang.org/x/oauth2 v0.36.0, Google OAuth2 native-app guide
// Confidence: HIGH — standard pattern

const (
    gmailComposeScope = "https://www.googleapis.com/auth/gmail.compose"
    gmailSendScope    = "https://www.googleapis.com/auth/gmail.send"
    userinfoEmailScope = "https://www.googleapis.com/auth/userinfo.email"  // needed for D-17 userinfo fetch
    userinfoProfileScope = "https://www.googleapis.com/auth/userinfo.profile"
)

func newOAuthConfig(redirectURL string) *oauth2.Config {
    return &oauth2.Config{
        ClientID:     oauthClientID,        // -ldflags injected
        ClientSecret: oauthClientSecret,    // -ldflags injected
        RedirectURL:  redirectURL,          // "http://127.0.0.1:{port}/callback" — port known after listener binds
        Scopes:       []string{gmailComposeScope, gmailSendScope, userinfoEmailScope, userinfoProfileScope},
        Endpoint:     google.Endpoint,      // from "golang.org/x/oauth2/google"
    }
}
```

Note: `google.Endpoint` requires `import "golang.org/x/oauth2/google"` — already under the `x/oauth2` module (no extra `go get`).

### Pattern 4: PKCE verifier + challenge (verified `x/oauth2` v0.36.0 API)

```go
// Source: pkg.go.dev/golang.org/x/oauth2 v0.36.0 [VERIFIED: exported names GenerateVerifier, S256ChallengeOption, VerifierOption]

verifier := oauth2.GenerateVerifier()  // returns 43-char base64url string, RFC 7636 compliant
authURL := cfg.AuthCodeURL(
    stateParam,                              // 32-byte crypto/rand base64url
    oauth2.AccessTypeOffline,                // request refresh_token
    oauth2.S256ChallengeOption(verifier),    // adds code_challenge + code_challenge_method=S256
    oauth2.SetAuthURLParam("prompt", "consent"),  // forces refresh_token even on re-auth
)

// Later, at callback:
token, err := cfg.Exchange(ctx, code, oauth2.VerifierOption(verifier))
```

**Do not hand-roll PKCE**: the three exported helpers above cover verifier generation, challenge attachment on `AuthCodeURL`, and verifier attachment on `Exchange`. Use them.

### Pattern 5: Loopback Listener Lifecycle

```go
// Source: RFC 8252 §7.3 + .planning/research/PITFALLS.md §4 + Go stdlib net/http idiom
// Confidence: HIGH

func (am *AuthManager) runLoopback(ctx context.Context) (code string, err error) {
    lis, err := net.Listen("tcp", "127.0.0.1:0")
    if err != nil {
        return "", fmt.Errorf("loopback listen: %w", err)
    }
    port := lis.Addr().(*net.TCPAddr).Port
    redirectURL := fmt.Sprintf("http://127.0.0.1:%d/callback", port)

    codeCh := make(chan string, 1)
    errCh := make(chan error, 1)

    srv := &http.Server{
        Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            if r.URL.Path != "/callback" {
                http.NotFound(w, r); return
            }
            q := r.URL.Query()
            if e := q.Get("error"); e != "" {
                errCh <- fmt.Errorf("oauth error: %s", e)
                fmt.Fprint(w, successHTML("Sign-in failed — you can close this tab."))
                return
            }
            if q.Get("state") != expectedState {
                errCh <- errors.New("state mismatch")   // CSRF defence
                fmt.Fprint(w, successHTML("Sign-in failed — you can close this tab."))
                return
            }
            codeCh <- q.Get("code")
            fmt.Fprint(w, successHTML("Signed in — you can close this tab."))
        }),
    }

    go func() { _ = srv.Serve(lis) }()
    defer func() { _ = srv.Shutdown(context.Background()) }()

    // Build authURL with redirectURL, open browser
    // Wait for code / error / timeout
    select {
    case code = <-codeCh:
        return code, nil
    case err = <-errCh:
        return "", err
    case <-ctx.Done():
        return "", ctx.Err()   // timeout or user cancel
    }
}
```

**Timeout (Claude discretion):** Recommend 5 minutes via `context.WithTimeout(ctx, 5*time.Minute)`. User's Cancel button in welcome screen calls a cancel-func stored on `AuthManager` to trigger the ctx.Done path early.

**Success HTML:** minimal inline HTML (no external assets) — a `<!doctype html><html><body><h2>...</h2><p>This tab can be closed.</p></body></html>` ~200 bytes. Prevents showing Google's OAuth server's raw JSON response.

### Pattern 6: Sign-in end-to-end

```go
func (am *AuthManager) SignIn(ctx context.Context) error {
    am.refresh.Lock()  // D-13 mutex — also prevents concurrent sign-ins
    defer am.refresh.Unlock()

    verifier := oauth2.GenerateVerifier()
    state := randomState()  // crypto/rand 32 bytes base64url

    flowCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
    defer cancel()
    am.cancelFlow = cancel  // stored for UI cancel button

    // listener + browser launch + code capture (Pattern 5)
    code, redirectURL, err := am.runLoopback(flowCtx, state)
    if err != nil { return err }

    cfg := newOAuthConfig(redirectURL)
    token, err := cfg.Exchange(flowCtx, code, oauth2.VerifierOption(verifier))
    if err != nil { return fmt.Errorf("token exchange: %w", err) }

    am.tokens = &OAuthTokens{
        AccessToken:  token.AccessToken,
        RefreshToken: token.RefreshToken,
        TokenType:    token.TokenType,
        Expiry:       token.Expiry,
    }
    if err := am.saveToKeyring(); err != nil { return err }

    // D-17: fetch userinfo (in-memory only)
    if err := am.fetchUserInfo(flowCtx); err != nil {
        logError("userinfo fetch failed (non-fatal): %v", err)  // non-fatal: user still signed in
    }
    return nil
}
```

### Anti-Patterns to Avoid

- **Holding refresh mutex across loopback wait:** Pattern 6 does hold the mutex for the full flow (5-min max), but because sign-in is user-initiated and serialized by the UI button state (D-07), contention is nonexistent. Alternative: use a separate `signingIn atomic.Bool` guard for the user-facing flow, reserve `refresh` mutex purely for token-refresh races during Gmail calls. Planner's call — both are acceptable.
- **Logging tokens:** Never pass `token.AccessToken` / `token.RefreshToken` / `code` / `verifier` to `logInfo`/`logError`. Log shape: `logInfo("oauth: token exchange succeeded, expires=%s", token.Expiry.Format(time.RFC3339))`.
- **Hand-rolled PKCE:** x/oauth2 v0.36.0 has it. Don't.
- **Embedded WebView2 for consent:** Explicitly forbidden by RFC 8252 and Google's terms. Use the system browser.
- **Storing tokens in file:** ARCH §Anti-Pattern 4. Fail hard per D-12 if keyring unavailable.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| PKCE verifier/challenge | Manual SHA256 + base64url | `oauth2.GenerateVerifier`, `oauth2.S256ChallengeOption`, `oauth2.VerifierOption` | Maintained, spec-correct, one line each |
| Token endpoint POST | Hand-rolled `http.Post` to `/token` | `cfg.Exchange(ctx, code, VerifierOption(v))` | Handles content-type, form encoding, error mapping |
| Refresh flow | Custom JSON → POST → parse | `cfg.TokenSource(ctx, token).Token()` | Handles concurrent refresh caching; but see note below |
| Keyring I/O | Win32 `CredRead`/`CredWrite` via syscall | `99designs/keyring` | Abstracts DPAPI; mockable in tests |
| Browser launch | Manual `exec.Command` with edge cases | `rundll32 url.dll,FileProtocolHandler` (one-liner) OR `github.com/pkg/browser` (already indirect dep) | Respects user default browser; no argv parsing traps |
| OAuth consent webview | Any embedded browser | System browser (RFC 8252) | Google rejects it; users can't verify origin |

**Note on `TokenSource`:** `oauth2.TokenSource` handles refresh internally, but CONTEXT D-13 specifies app-level refresh with mutex and `invalid_grant` detection for re-auth UX. The cleanest path is to implement refresh manually using `cfg.Client` or a direct `POST /token` — that's what lets us distinguish `invalid_grant` from transient failures and emit `auth-changed`. `TokenSource` swallows the distinction. **Planner decides**: hand-rolled refresh POST is acceptable here because the logic (classify error → emit event → clear keyring) is what makes D-05 possible.

**Key insight:** The `x/oauth2` library is perfect for config + AuthCodeURL + Exchange + PKCE. The one place we step outside it is the refresh call, because we need to introspect `invalid_grant` specifically. That's 20 lines of `http.PostForm` + JSON decode — trivial to write, trivial to test, worth the clarity.

## Technical Details (planner-facing)

### 99designs/keyring Windows Specifics

```go
// Source: github.com/99designs/keyring README + source v1.2.x
// Confidence: HIGH — standard config for Windows-only apps

import "github.com/99designs/keyring"

func openKeyring() (keyring.Keyring, error) {
    return keyring.Open(keyring.Config{
        ServiceName:     "go-mapi",                          // D-11
        AllowedBackends: []keyring.BackendType{keyring.WinCredBackend},
        // Windows-only: no WindowsCredNamePrefix override needed; default is fine.
    })
}

// Read: returns keyring.ErrKeyNotFound when item absent — distinct from other errors.
item, err := ring.Get("oauth-tokens")
if errors.Is(err, keyring.ErrKeyNotFound) {
    // Signed out / first run — emit AuthStatus{Authenticated:false}
}
```

**Error modes on Windows:**
- `keyring.ErrKeyNotFound` — no entry yet; treat as "signed out". SignOut when not signed in = no-op (D-12).
- Any other error from `keyring.Open` — credential store unavailable/locked. **Fail hard at sign-in time** per D-12. Surface via welcome screen / re-auth banner. Do NOT fall back to file.
- On write errors (rare — Credential Manager quota is ~8KB per item; our JSON is ~500 bytes): surface as sign-in error; keyring state remains consistent (no partial write).

**Payload shape (D-11):**
```json
{
  "access_token": "ya29....",
  "refresh_token": "1//0e...",
  "token_type": "Bearer",
  "expiry": "2026-04-15T13:45:12Z"
}
```

### PKCE S256 Exact Spec (for validation / test assertions)

[CITED: RFC 7636 §4.1–4.2]
- Verifier: 43–128 chars from `[A-Z][a-z][0-9]-._~`. `oauth2.GenerateVerifier()` outputs 43 chars (URL-safe base64 of 32 random bytes, no padding) [VERIFIED: x/oauth2 v0.36.0 source — returns `base64.RawURLEncoding.EncodeToString(32 bytes from crypto/rand)`].
- Challenge (S256): `base64url(sha256(verifier))`, no padding. Produced by `oauth2.S256ChallengeOption(verifier)` as an `AuthCodeOption` adding `code_challenge` + `code_challenge_method=S256` to the URL.
- Exchange: pass `oauth2.VerifierOption(verifier)` to `cfg.Exchange` — injects `code_verifier` form field.

Test assertions (unit): `len(oauth2.GenerateVerifier()) == 43`; URL from `AuthCodeURL` contains `code_challenge_method=S256` and a 43-char base64url `code_challenge`.

### Loopback Listener Pattern (additional notes)

- **IPv6 fallback:** FEATURES.md §4 suggests trying `[::1]:0` if `127.0.0.1:0` fails. In practice on Windows 10/11 this is near-never needed; recommend **not** implementing until a real user report surfaces. Skip for Phase 8 to stay minimal.
- **Graceful shutdown:** `srv.Shutdown(context.Background())` after the select returns. The handler's write has already flushed the success page by then.
- **Duplicate callbacks:** `chan string` with buffer 1 — second write would block, but the handler is wired to close after first response anyway. Defence-in-depth: add a `sync.Once` around the channel sends.
- **Firewall prompt (PITFALLS §4):** Binding to `127.0.0.1` specifically (not `0.0.0.0` or `localhost`) minimizes the Windows Firewall "Allow app?" prompt surface. The installer firewall rule (Phase 10) is the durable fix; Phase 8 ships without it and accepts a possible one-time user prompt on RDS.

### URL Opener on Windows

**Recommendation: `exec.Command("rundll32", "url.dll,FileProtocolHandler", authURL)`**

```go
// Source: FEATURES.md §4, verified pattern on Windows 10/11
// Confidence: HIGH — `rundll32 url.dll,FileProtocolHandler` is the documented shell-compat path

func openBrowser(url string) error {
    cmd := exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
    return cmd.Start()  // do NOT Run/Wait — browser is detached
}
```

Why:
- Respects the user's configured default browser (Chrome, Edge, Firefox).
- Stdlib-only, zero deps.
- URL is passed as a single argv element — no shell-quoting issues.
- `cmd.Start()` (not `Run`) returns immediately; the browser outlives us.

Edge cases:
- User has no default browser set (rare; Windows 10/11 always has Edge). `rundll32` returns success anyway; Edge opens. Not our problem.
- URL contains characters problematic for command lines: `oauth2.AuthCodeURL` already returns a proper percent-encoded URL. No extra escaping needed.
- `pkg/browser` (already an indirect Wails dep) is an acceptable substitute — single-line `browser.OpenURL(url)`. Planner's call; both are fine. Prefer stdlib for explicitness.

### Userinfo Endpoint (D-17)

```
GET https://www.googleapis.com/oauth2/v3/userinfo
Authorization: Bearer {access_token}
```

Response (JSON) [CITED: developers.google.com/identity/openid-connect/openid-connect#obtaininguserprofileinformation]:
```json
{
  "sub": "110169484474386276334",      // stable Google user ID
  "name": "Marc Fargas",
  "given_name": "Marc",
  "family_name": "Fargas",
  "picture": "https://lh3.googleusercontent.com/...",
  "email": "marc@example.com",
  "email_verified": true,
  "locale": "en"
}
```

Store `email` and `name` on `AuthManager` in memory; never write to disk (D-17, QUAL-03). Requires `userinfo.email` + `userinfo.profile` scopes in the OAuth config (added in Pattern 3 above).

Error responses:
- 401 → access token expired; refresh and retry once. If still 401, treat as `invalid_grant` path (emit auth-changed:false, clear keyring).
- 403 → scope missing (misconfiguration) — log error; non-fatal for sign-in (user can still create drafts without userinfo display). Fall back to displaying "Signed in" without email.

### Token Refresh Mechanics (extends ARCH §5)

```go
// Source: extends .planning/research/ARCHITECTURE.md §5 + CONTEXT D-13, D-14
// Hand-rolled POST (not TokenSource) to introspect invalid_grant — see §Don't Hand-Roll note

func (am *AuthManager) refreshIfNeeded(ctx context.Context) error {
    am.refresh.Lock()
    defer am.refresh.Unlock()

    if am.tokens == nil { return ErrNotAuthenticated }
    if time.Until(am.tokens.Expiry) > 5*time.Minute { return nil }  // fast path

    // POST https://oauth2.googleapis.com/token
    form := url.Values{
        "client_id":     {oauthClientID},
        "client_secret": {oauthClientSecret},
        "refresh_token": {am.tokens.RefreshToken},
        "grant_type":    {"refresh_token"},
    }
    resp, err := http.PostForm("https://oauth2.googleapis.com/token", form)
    if err != nil { return fmt.Errorf("refresh: %w", err) }
    defer resp.Body.Close()

    if resp.StatusCode == 400 {
        // Parse body for {"error":"invalid_grant"}
        var e struct{ Error string `json:"error"` }
        _ = json.NewDecoder(resp.Body).Decode(&e)
        if e.Error == "invalid_grant" {
            am.clearTokens()
            // Emit auth-changed{authenticated:false} via App struct
            return ErrInvalidGrant
        }
    }
    // ... parse successful response, update am.tokens, save to keyring
}
```

**401 reactive path (D-13):** `App.makeAuthenticatedGmailCall` wraps the `GmailClient.CreateDraft`; on 401, calls `refreshIfNeeded` then retries once. If retry also returns 401, classify as invalid_grant and emit event.

**Error classification table:**
| From | Code / body | Meaning | Action |
|------|-------------|---------|--------|
| `/token` refresh | 400 `invalid_grant` | Refresh token revoked / expired | Clear keyring, emit `auth-changed{false}`, show banner |
| `/token` refresh | 400 `invalid_client` | `client_secret` rotated | Log fatal; user re-sign-in will also fail; same UX as `invalid_grant` for now |
| `/token` refresh | 5xx / network error | Transient | Log error; retry once with backoff; bubble up to caller for a single UI error toast (no sign-out) |
| Gmail API | 401 | Access token expired | Refresh + retry once |
| Gmail API | 401 after refresh | Refresh returned fresh token but Gmail still rejects | Treat as `invalid_grant` path |

### Revoke Endpoint (D-15 sign-out)

```
POST https://oauth2.googleapis.com/revoke
Content-Type: application/x-www-form-urlencoded
Body: token={refresh_token}
```

[CITED: developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke]

- 200 = success.
- 400 with body `{"error":"invalid_token"}` = already revoked → **treat as success** (idempotent).
- Timeout: 5s per CONTEXT §specifics. Use `http.Client{Timeout: 5*time.Second}`.
- Failure (network, 5xx) is **logged only, not surfaced**; keyring clears unconditionally (D-15).

```go
func (am *AuthManager) revokeRefreshToken(ctx context.Context) {
    if am.tokens == nil || am.tokens.RefreshToken == "" { return }
    c := &http.Client{Timeout: 5 * time.Second}
    req, _ := http.NewRequestWithContext(ctx, "POST",
        "https://oauth2.googleapis.com/revoke",
        strings.NewReader("token="+url.QueryEscape(am.tokens.RefreshToken)))
    req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
    resp, err := c.Do(req)
    if err != nil {
        logError("oauth revoke: %v", err); return
    }
    defer resp.Body.Close()
    if resp.StatusCode != 200 && resp.StatusCode != 400 {
        logError("oauth revoke: status %d", resp.StatusCode)
    }
}
```

### Build-Time -ldflags Injection (D-08, D-09)

**Declaration (auth_credentials.go):**
```go
package main

// Injected at build time via:
//   -ldflags "-X 'main.oauthClientID=...' -X 'main.oauthClientSecret=...'"
// `var` (not const) is REQUIRED — -X only works on string vars.
var (
    oauthClientID     = ""
    oauthClientSecret = ""
)
```

**Verified with repo pattern:** `src/app/main.go` line 15 already uses this pattern successfully: `var Version = "0.0.0-dev" // overridden via -ldflags "-X main.Version=..."`. Same mechanism works for credentials.

**Build command (local dev / CI):**
```bash
# Local: via env vars loaded from gitignored .env.local (D-09)
export GOMAPI_OAUTH_CLIENT_ID="..."
export GOMAPI_OAUTH_CLIENT_SECRET="..."
wails build -ldflags "-X 'main.oauthClientID=$GOMAPI_OAUTH_CLIENT_ID' -X 'main.oauthClientSecret=$GOMAPI_OAUTH_CLIENT_SECRET'"
```

**Runtime fallback pattern (D-09 dev env var injection):**

Wails dev mode (`wails dev`) rebuilds the binary fresh each time and does NOT automatically load `.env` files. Two clean options:

1. **Pre-build env substitution (recommended):** a `scripts/dev.ps1` or `scripts/dev.sh` reads `.env.local`, sets vars, and calls `wails dev -ldflags "-X ..."`. Same injection as CI — no runtime divergence.
2. **Runtime env-var read with ldflags fallback:** in `init()`, read `os.Getenv("GOMAPI_OAUTH_CLIENT_ID")`; if non-empty, overwrite the `-ldflags`-injected value. Cleaner for `wails dev` but adds a second code path.

```go
func init() {
    if v := os.Getenv("GOMAPI_OAUTH_CLIENT_ID"); v != "" {
        oauthClientID = v
    }
    if v := os.Getenv("GOMAPI_OAUTH_CLIENT_SECRET"); v != "" {
        oauthClientSecret = v
    }
}
```

Planner picks. Option 2 is simpler for the developer; Option 1 is more faithful to the release posture. Both satisfy D-09 / D-10.

**D-10 fatal check** (in startup):
```go
if oauthClientID == "" || oauthClientSecret == "" {
    logError("FATAL: OAuth client credentials missing — build was not wired correctly")
    os.Exit(1)   // before Wails init; no window
}
```

### Wails v2 Bindings (D-19)

The App struct in `src/app/app.go` is already wired into `wails.Run` via `Bind: []interface{}{app}` (main.go line 48). **Any new exported method on `*App` becomes a frontend binding automatically.** Phase 8 adds:

```go
func (a *App) GetAuthStatus() AuthStatus { /* read am.tokens + am.email + am.name */ }
func (a *App) SignIn() error             { return a.auth.SignIn(a.ctx) }
func (a *App) SignOut() error            { return a.auth.SignOut(a.ctx) }
```

Wails auto-regenerates `frontend/wailsjs/go/main/App.{d.ts,js}` on build — planner should note the diff against the currently committed generated files (in `git status` above).

**Event:** `auth-changed` with `AuthStatus` payload emitted via `wruntime.EventsEmit(a.ctx, "auth-changed", status)` in three places: `OnStartup` (post keyring load), `SignIn` success, `SignOut`.

## Common Pitfalls

### Pitfall 1: Hand-rolled refresh loses `invalid_grant` classification
**What goes wrong:** Using `oauth2.TokenSource` for refresh — it bundles errors into a generic `*oauth2.RetrieveError` without always preserving the `error` field.
**Why it happens:** Convenience API is tuned for server-side apps where any refresh failure means re-auth anyway.
**How to avoid:** Use direct `http.PostForm` to `/token` and parse `{"error":"invalid_grant"}` explicitly.
**Warning signs:** Users report "sign-in expired" banner firing on network blips.

### Pitfall 2: Mutex held across loopback wait starves refresh
**What goes wrong:** `refresh` mutex held for 5 minutes during sign-in; concurrent Gmail call blocks.
**Why it happens:** Pattern 6 snippet shows this — simpler to reason about but blocks.
**How to avoid:** Either (a) separate `signingIn atomic.Bool` from `refresh sync.Mutex`, or (b) accept the block because during sign-in there's no token to use anyway (draft buttons disabled per D-07). Option (b) is simplest; Phase 8 scope makes it safe.

### Pitfall 3: Logging leaks tokens
**What goes wrong:** `logInfo("exchange response: %+v", token)` prints AccessToken.
**Why it happens:** Debugging convenience.
**How to avoid:** Never `%+v` or `%v` an `OAuthTokens` or `oauth2.Token`. Log expiry timestamps and scopes only. Add a golangci-lint rule or grep check: no `%v`/`%+v`/`%#v` on identifier names containing `token`/`tokens`/`Token`.

### Pitfall 4: State parameter CSRF
**What goes wrong:** Loopback callback accepts any `code` without verifying `state`.
**Why it happens:** PKCE already prevents code interception; developer assumes state is redundant.
**How to avoid:** Always generate 32-byte `crypto/rand` state, compare in callback, reject mismatch. PITFALLS.md §Security lists this explicitly.
**Warning signs:** N/A — attack is silent if exploited.

### Pitfall 5: Firewall prompt hangs OAuth on RDS (PITFALLS §4)
**What goes wrong:** First `net.Listen` triggers Windows Firewall "Allow?" dialog on the console session, invisible to the RDP user.
**Why it happens:** Windows blocks inbound listening until approved.
**How to avoid:** Installer creates `New-NetFirewallRule` for `go-mapi.exe` (Phase 10). Phase 8 ships without it and accepts a possible one-time prompt on first RDS deployment. Document in phase SUMMARY.
**Warning signs:** OAuth flow opens browser, user grants consent, callback never fires.

### Pitfall 6: Keyring entry survives app uninstall
**What goes wrong:** User uninstalls go-mapi; refresh token stays in Credential Manager.
**Why it happens:** No one ever ran `ring.Remove`.
**How to avoid:** Phase 10 installer uninstaller runs a pre-uninstall step (e.g., small cleanup binary or `cmdkey /delete:go-mapi`). Out of scope for Phase 8 — note for Phase 10 CONTEXT.

### Pitfall 7: Google OAuth 100-user cap on unverified app (PITFALLS §3, CONTEXT D-01)
**What goes wrong:** Day-N user after 100 sees "User cap reached", can't sign in.
**Why it happens:** Unverified apps are permanently capped.
**How to avoid:** Verification filed day 1 (D-01 owner task). Acceptable for FOSS pre-v3.0 release.

### Pitfall 8: "Testing" mode refresh tokens expire in 7 days (PITFALLS §5)
**What goes wrong:** Dev refresh tokens die weekly during development.
**Why it happens:** Google policy for apps in Testing status.
**How to avoid:** Accept as dev friction; do not use in CI integration fixtures (PITFALLS §5). Submit for "In production" status at verification time.

## Code Examples

### Full `saveToKeyring` / `loadFromKeyring`

```go
// Source: 99designs/keyring README + CONTEXT D-11
func (am *AuthManager) saveToKeyring() error {
    data, err := json.Marshal(am.tokens)
    if err != nil { return err }
    return am.ring.Set(keyring.Item{
        Key:   "oauth-tokens",
        Data:  data,
        Label: "go-mapi OAuth tokens",   // shown in Credential Manager UI
    })
}

func (am *AuthManager) loadFromKeyring() error {
    item, err := am.ring.Get("oauth-tokens")
    if errors.Is(err, keyring.ErrKeyNotFound) {
        am.tokens = nil
        return nil
    }
    if err != nil { return err }
    var t OAuthTokens
    if err := json.Unmarshal(item.Data, &t); err != nil { return err }
    am.tokens = &t
    return nil
}

func (am *AuthManager) clearTokens() {
    am.tokens = nil
    am.email = ""
    am.name = ""
    _ = am.ring.Remove("oauth-tokens")  // ignore "not found"
}
```

### Random state generation

```go
func randomState() string {
    b := make([]byte, 32)
    if _, err := rand.Read(b); err != nil {
        panic(err)  // crypto/rand failure = catastrophic
    }
    return base64.RawURLEncoding.EncodeToString(b)
}
```

## State of the Art

| Old (v2.x) Approach | v3.0 Approach | When Changed | Impact |
|---------------------|---------------|--------------|--------|
| `chrome.identity.getAuthToken()` (Chrome-managed) | Desktop loopback + PKCE via `x/oauth2` | v3.0 pivot | App owns full token lifecycle; implements refresh + revoke itself |
| Token held in Chrome's credential store | Windows Credential Manager via `99designs/keyring` | v3.0 pivot | DPAPI-backed, user-scoped, survives app restart; does NOT roam across RDS hosts (PITFALLS §6) |
| 100-test-user cap bypassed via Chrome's verified client | Need our own Google verification (D-01) | v3.0 pivot | 4–8 week external review window; file day 1 |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `oauth2.GenerateVerifier()` returns a 43-char base64url string (32 random bytes) | §PKCE S256 Exact Spec | Tests against length assertion fail; pick verifier length dynamically instead. Minor. [Mitigation: verified via pkg.go.dev export list and x/oauth2 v0.36.0 source comments, but behavior not executed here] |
| A2 | `99designs/keyring` v1.2.2 `WinCredBackend` constant name is unchanged from earlier versions | §99designs/keyring Windows Specifics | Compile error; trivial fix (check `keyring.BackendType` constants in module source). |
| A3 | Wails v2.12.0's `wruntime.EventsEmit` marshals arbitrary structs to JSON for the frontend event payload | §Pattern 2 | Event payload arrives as `undefined` in frontend; fix by marshaling to `map[string]any` explicitly. Phase 7 already uses `EventsEmit` for `queue-update` — check existing payload shape in `src/app/watcher_bridge.go` to confirm. |
| A4 | Windows Firewall does NOT prompt for `127.0.0.1` loopback listeners on Windows 10/11 consumer editions (only Server/RDS) | §Pitfall 5 | Phase 8 dev experience hits unexpected prompt; not blocking. |
| A5 | Google's `/revoke` endpoint treats 400 `invalid_token` as idempotent success | §Revoke Endpoint | Sign-out logs a spurious error; UX still works (keyring cleared). [CITED: developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke documents 400 behaviour but real-world response variants not tested] |
| A6 | The conflict between CONTEXT D-11 (99designs/keyring) and SUMMARY.md "library conflict" note (zalando/go-keyring) is resolved by CONTEXT precedence — user explicitly chose 99designs | §Summary | If user intended SUMMARY's "use zalando" to override, we'll build against the wrong library. Flagged in Open Questions #1 for confirmation before Task 1 implementation. |

## Open Questions

1. **Keyring library: confirm CONTEXT D-11 over SUMMARY.md "minor library conflict" note.**
   - What we know: CONTEXT.md D-11 explicitly names `99designs/keyring`. SUMMARY.md §"Minor library conflict" recommends `zalando/go-keyring` as simpler. STACK.md picks zalando.
   - What's unclear: whether the CONTEXT author intentionally overrode SUMMARY or missed the recommendation.
   - Recommendation: **Confirm with user before planning** — single sentence in discuss-phase. If user says "stick with CONTEXT", proceed with 99designs. If user agrees SUMMARY's simpler-API reasoning is stronger, swap to zalando (smaller diff — just Open/Set/Get/Delete API changes).

2. **URL opener: `rundll32` vs `pkg/browser`.**
   - What we know: `pkg/browser` is already an indirect dep (Wails pulls it).
   - What's unclear: whether the "zero new deps" preference in CONTEXT §Discretion outweighs the one-liner cleanliness of `browser.OpenURL`.
   - Recommendation: Planner picks; both are under CONTEXT Claude's Discretion. Default to `rundll32` stdlib for explicitness.

3. **Dev env var injection strategy: build-script vs runtime-fallback.**
   - What we know: D-09 requires env vars at `wails dev` time; fallback to `-ldflags` at release.
   - What's unclear: Marc's preference for `scripts/dev.ps1` (matches release posture exactly) vs runtime `init()` env-var read (simpler workflow).
   - Recommendation: Ship runtime fallback (Option 2 in §Build-Time -ldflags). Add a `scripts/dev.ps1` wrapper in a later iteration if Option 1 is preferred.

4. **Toast stub for D-05c: trivial in Phase 8 or defer?**
   - What we know: CONTEXT says "implement trivially if a few lines, otherwise defer to Phase 9".
   - What's unclear: without AppUserModelID registration (Phase 10), toasts may not persist in Action Center — they'd vanish on dismiss. Is that acceptable for the re-auth signal?
   - Recommendation: **Defer to Phase 9.** Banner + tray icon is already two concurrent signals; a transient toast with no Action Center persistence adds little. Keeps Phase 8 scope tight.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Go toolchain | Build | ✓ | 1.23 (per `src/app/go.mod`) | — |
| Wails v2 CLI | `wails dev` / `wails build` | ✓ | v2.12.0 (per `src/app/go.mod`) | — |
| `golang.org/x/oauth2` | auth.go | To add | v0.36.0 | — |
| `github.com/99designs/keyring` | auth.go | To add | v1.2.2 | — |
| Windows Credential Manager | keyring backend | ✓ (all Win10/11) | OS-native | None — fail hard per D-12 |
| GCP OAuth desktop client credentials | Runtime (ldflags/env) | **✗ (requires D-01 day 1 owner action)** | — | None — fatal at startup per D-10 |
| System default browser | Consent flow | ✓ (Edge on all Win10/11) | — | — |
| WebView2 runtime | Wails window | ✓ (Phase 7 confirmed) | Evergreen | Phase 10 installer bootstraps |

**Missing dependencies with no fallback:**
- GCP desktop OAuth client_id / client_secret — **Marc owns this as a day-1 task** (AUTH-06 pending todo in STATE.md). Must land before any Phase 8 task can produce a runnable build. Planner: first phase plan should verify credentials are available (e.g., "Plan 0: prerequisites — GCP desktop client created; credentials in Marc's .env.local").

**Missing dependencies with fallback:**
- None.

## Project Constraints (from CLAUDE.md)

- **Language:** Go 1.23 in `src/app/` (matches workspace).
- **License:** LGPL-3.0 — all deps must be compatible. `x/oauth2` (BSD-3), `99designs/keyring` (MIT) — both compatible [VERIFIED: licenses on github.com].
- **Privacy:** No telemetry, no long-term content storage, no network calls outside Gmail API + GitHub Releases. Phase 8 adds calls to: `accounts.google.com` (auth), `oauth2.googleapis.com` (token, revoke), `googleapis.com/oauth2/v3/userinfo`. All Google-owned, all required for the Gmail feature — within QUAL-03 spirit.
- **Logging discipline:** Never log tokens; `logInfo`/`logError` only with safe fields. Match Phase 7 `%APPDATA%\go-mapi\app.log` format (RFC3339 + level prefix).
- **Error wrapping:** `%w` verb; lowercase error strings (CONVENTIONS.md).
- **RTK prefix** for git commands during dev (user instruction).
- **GSD workflow:** No direct repo edits outside a GSD command (user instruction).
- **Go 1.21+** stated in project CLAUDE.md, but `go.mod` uses 1.23 (already upgraded in Phase 7). Phase 8 inherits.
- **Read-before-write:** existing `src/app/app.go`, `main.go`, `logging.go` must not regress. Phase 8 **adds** fields to App struct and adds new files — no destructive edits to Phase 7 code expected.

## Sources

### Primary (HIGH confidence)
- `.planning/research/ARCHITECTURE.md` §5 OAuth Token Storage and Refresh — primary reference, extended not duplicated here
- `.planning/research/ARCHITECTURE.md` §Anti-Pattern 4 (no file-based storage)
- `.planning/research/FEATURES.md` §4 Desktop OAuth Flow
- `.planning/research/PITFALLS.md` §3 (100-user cap), §4 (loopback port/firewall), §5 (refresh invalidation), §6 (RDS credential scope), §Security (state CSRF, token storage)
- [Google OAuth 2.0 for Native Apps](https://developers.google.com/identity/protocols/oauth2/native-app) — loopback redirect pattern
- [Google Loopback Migration Guide](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration) — 127.0.0.1 any-port policy
- [Google Token Revoke](https://developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke)
- [RFC 8252 OAuth 2.0 for Native Apps](https://www.rfc-editor.org/rfc/rfc8252.html) — loopback + system browser mandate
- [RFC 7636 PKCE](https://www.rfc-editor.org/rfc/rfc7636.html) — verifier/challenge spec
- [pkg.go.dev/golang.org/x/oauth2](https://pkg.go.dev/golang.org/x/oauth2) — `GenerateVerifier`, `S256ChallengeOption`, `VerifierOption` exports [VERIFIED]
- `proxy.golang.org` — latest version list for x/oauth2, 99designs/keyring, zalando/go-keyring [VERIFIED 2026-04-15]
- `src/app/` in-tree code — App struct, ldflags pattern, Wails event pattern [VERIFIED: read]

### Secondary (MEDIUM confidence)
- [99designs/keyring README](https://github.com/99designs/keyring) — WinCredBackend usage
- [Google OpenID Connect Userinfo](https://developers.google.com/identity/openid-connect/openid-connect#obtaininguserprofileinformation) — userinfo response shape

### Tertiary (LOW confidence / assumption-tagged)
- Firewall prompt behavior variance across Win10/11 editions (A4)
- `99designs/keyring` v1.2.2 exact error sentinel naming (A2)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — versions verified against Go proxy; pkg.go.dev exports verified for x/oauth2.
- Architecture patterns: HIGH — extending ARCH §5 which is locked; Phase 7 code in-tree confirms Wails event pattern.
- Pitfalls: HIGH — sourced from existing PITFALLS.md which is MEDIUM-HIGH itself, plus standard OAuth best-practices.
- Build-time ldflags: HIGH — same pattern already works for `main.Version` in `src/app/main.go`.
- Dev env-var loading: MEDIUM — two viable approaches; user/planner picks.

**Research date:** 2026-04-15
**Valid until:** 2026-05-15 (30-day stable) — re-verify module versions if planning slips; OAuth endpoints and PKCE spec are stable indefinitely.
