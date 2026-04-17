---
phase: 08-oauth-credentials
reviewed: 2026-04-18T00:00:00Z
depth: standard
files_reviewed: 11
files_reviewed_list:
  - src/app/app.go
  - src/app/auth.go
  - src/app/auth_test.go
  - src/app/frontend/src/App.svelte
  - src/app/frontend/src/lib/auth.ts
  - src/app/frontend/src/lib/components/PreAuthModal.svelte
  - src/app/frontend/src/lib/components/ReAuthBanner.svelte
  - src/app/frontend/src/lib/components/SignInScreen.svelte
  - src/app/frontend/src/lib/components/SignedInHeader.svelte
  - src/app/frontend/src/lib/queue.ts
  - src/app/go.mod
findings:
  critical: 1
  warning: 4
  info: 3
  total: 8
status: issues_found
---

# Phase 08: Code Review Report

**Reviewed:** 2026-04-18T00:00:00Z
**Depth:** standard
**Files Reviewed:** 11
**Status:** issues_found

## Summary

Phase 08 implements the full OAuth 2.0 desktop loopback flow (PKCE, state CSRF, token refresh/revoke, Windows Credential Manager persistence, and the Svelte sign-in UI). The architecture is sound and most of the hard parts are handled correctly: PKCE verifier is generated via `oauth2.GenerateVerifier()` (S256), state is a 32-byte CSPRNG value, loopback is bound on 127.0.0.1 only, token content is never logged (only expiry timestamps), and userinfo fields are in-memory only (D-17 satisfied). The test suite covers the critical paths thoroughly.

One critical issue is present: the `openBrowser` function passes the full OAuth authorization URL as a positional argument to `rundll32`, which opens a command-injection vector for specially crafted redirect URLs or future changes to the URL-construction path. Three warnings cover real behavioural gaps: (1) a double-emit of `auth-changed` at bootstrap that can briefly show a stale signed-out UI flash, (2) the `refresh` mutex is used for unrelated purposes (sign-in + revoke) in a way that could deadlock if `ClearTokens` is ever called from within a mutex-holding call path, and (3) `subscribeQueue` in `queue.ts` silently swallows fetch errors on every queue-update event. Three info items cover minor quality concerns.

## Critical Issues

### CR-01: `openBrowser` passes auth URL as unquoted rundll32 argument — command injection risk

**File:** `src/app/auth.go:201-204`

**Issue:** `openBrowser` constructs `exec.Command("rundll32", "url.dll,FileProtocolHandler", authURL)` where `authURL` is built from `cfg.AuthCodeURL(...)`. `exec.Command` with explicit args does NOT invoke a shell, so there is no shell injection in the traditional sense. However, `rundll32.exe` does its own argument parsing: it passes the third positional argument to `ShellExecuteW` as the URL string. If the URL contains characters interpreted by `ShellExecuteW` or future changes introduce a different URL-building path that could be influenced by attacker-controlled redirect URI fragments, the blast radius widens.

More concretely: `oauthClientSecret` flows into `newOAuthConfig` and then into `cfg.AuthCodeURL`, which appends a `client_secret` parameter to the URL. A logging statement on line 357 (`logInfo("oauth: opening browser for sign-in (redirect=%s)", redirectURL)`) logs the redirect URL. The full auth URL (with `client_secret` if the library were ever to include it, or with `code` in error paths) is passed verbatim to `rundll32`. The safe pattern on Windows for opening a URL without touching rundll32 is `cmd /c start "" <url>` — but this introduces a shell. The correct fix is to use the `golang.org/x/sys/windows` API or the already-present `github.com/pkg/browser` indirect dependency.

**Fix:**
```go
import "github.com/pkg/browser"

// openBrowser launches the default browser using the cross-platform browser
// package (already in go.sum as an indirect dep of Wails). This avoids passing
// the auth URL as a rundll32 argument.
func openBrowser(authURL string) error {
    return browser.OpenURL(authURL)
}
```

`github.com/pkg/browser` is already in `go.mod` as an indirect dependency (line 33). Promoting it to direct removes the `rundll32` surface entirely with zero new dependencies.

## Warnings

### WR-01: Double `auth-changed` emission at bootstrap races with async userinfo goroutine

**File:** `src/app/auth.go:706-713`

**Issue:** `bootstrapAuth` emits `auth-changed` twice in the happy path: once at line 713 (synchronously, without email/name) and once at the end of the goroutine launched at line 706 (with email/name populated). Between these two emissions the Svelte frontend renders a `SignedInHeader` with empty strings for both `email` and `name`, causing a brief visual flash.

More importantly, the goroutine at line 706 holds `am.refresh` and calls `fetchUserInfoLocked`. If `SignIn` or `SignOut` is called during startup (e.g., user clicks the tray icon very quickly), `SignIn` will deadlock waiting for the mutex held by the goroutine, because `SignIn` also calls `a.auth.refresh.Lock()` from `a.App.SignIn()`.

In practice the race window is small (the 10s userinfo HTTP timeout), but it is a real deadlock path during the 5-minute loopback flow timeout.

**Fix:** Emit `auth-changed` only once, after the goroutine completes, OR emit twice but with a flag so the frontend knows to treat the first emission as a signed-in-but-loading state. The simpler fix is to not emit before the goroutine and let the goroutine do a single emit:

```go
// bootstrapAuth, happy path — replace lines 706-713 with:
go func() {
    a.auth.refresh.Lock()
    a.auth.fetchUserInfoLocked(a.ctx)
    a.auth.refresh.Unlock()
    a.emitAuthChanged() // single emission, email/name populated
}()
logInfo("oauth bootstrap: signed in, token expires %s", a.auth.tokens.Expiry.Format(time.RFC3339))
// Do NOT emit here — let the goroutine do it.
```

This removes the double-emit flash and eliminates the partial-state window. The authenticated queue view renders slightly later (10s worst case) but without a stale-name flash.

### WR-02: `ClearTokens` acquires `am.refresh` but `MakeAuthenticatedGmailCall` calls it without the mutex after a double-401

**File:** `src/app/auth.go:619-626`

**Issue:** In the second-401 path of `MakeAuthenticatedGmailCall` (line 622), the mutex is released on line 617 (`a.auth.refresh.Unlock()`) and then `a.auth.ClearTokens()` is called on line 622. `ClearTokens` internally re-acquires `am.refresh`. Between the Unlock on line 617 and the `ClearTokens` call on line 622, another goroutine (e.g., a concurrent proactive refresh from a second Gmail call) can observe a non-nil `am.tokens` and proceed with the stale token, then race against `ClearTokens` resetting to nil.

```go
// Current (line 617-626):
a.auth.refresh.Unlock()

status, err = fn(token)
if status == 401 {
    _ = a.auth.ClearTokens()   // lock gap here — tokens observable between Unlock above and this Lock
    a.emitAuthChanged()
    ...
}
```

**Fix:** Either (a) stay locked through the clear:
```go
// After retry fn call, before Unlock:
if status == 401 {
    am.tokens = nil
    am.email = ""
    am.name = ""
    _ = keyring.Delete(keyringService, keyringUser)
    a.auth.refresh.Unlock()
    a.emitAuthChanged()
    a.SetTrayError("sign-in expired")
    return ErrInvalidGrant
}
a.auth.refresh.Unlock()
return err
```
Or (b) keep `ClearTokens` but call it while holding the lock via a locked variant (following the existing `saveToKeyringLocked` pattern).

### WR-03: `subscribeQueue` silently drops fetch errors on every queue-update event

**File:** `src/app/frontend/src/lib/queue.ts:18-22`

**Issue:** The `subscribeQueue` callback calls `fetchQueue()` which can reject (network/IPC error). The rejection is unhandled — there is no `.catch()` and the `async` callback inside `EventsOn` is not awaited by the event system. Any error silently vanishes; the `onChange` callback is never called, so the UI freezes at the last-known queue snapshot with no error surfaced.

```typescript
// Current:
return EventsOn('queue-update', async () => {
    onChange(await fetchQueue());  // rejection swallowed if fetchQueue() rejects
});
```

**Fix:**
```typescript
return EventsOn('queue-update', () => {
    fetchQueue()
        .then(onChange)
        .catch((e: unknown) => {
            // Surface the error to the caller via a second callback, or at minimum log it.
            console.error('[go-mapi] queue fetch failed:', e);
        });
});
```

The `App.svelte` already handles a `queue-error` event and sets `errorMsg`. A cleaner approach is to have `subscribeQueue` accept an optional error callback and call it on rejection, so the UI can surface the error rather than silently freezing.

### WR-04: `signInLocked` is called while holding `am.refresh`, blocking all Status() reads for up to 5 minutes

**File:** `src/app/auth.go:408-425` (caller: `App.SignIn`)

**Issue:** `App.SignIn` acquires `a.auth.refresh.Lock()` and then calls `a.auth.signInLocked(a.ctx)` which can block for up to `loopbackFlowTimeout` (5 minutes) waiting for the browser callback. During this entire window, `Status()` also tries to acquire `am.refresh.Lock()` and deadlocks. Any call to `GetAuthStatus()` from the frontend (e.g., on re-mount after the window is hidden and shown) will block indefinitely until the sign-in completes or times out.

The comment on the struct field (`refresh sync.Mutex`) acknowledges sign-in contention is "impossible in practice" because draft buttons are disabled during sign-in. However, the frontend calls `GetAuthStatus()` via Wails on every mount (App.svelte line 33), and the window can be hidden and re-shown by the tray icon during the 5-minute browser wait.

**Fix:** Use `sync.RWMutex` for `Status()` reads, or store sign-in state as a separate field that `Status()` can read without locking. The minimal fix is to rename the mutex to reflect its true scope:

```go
// Replace sync.Mutex with sync.RWMutex for the tokens/email/name fields.
// Status() takes RLock; all mutation paths (signInLocked, refreshIfNeededLocked,
// ClearTokens, etc.) take Lock as today.
mu sync.RWMutex

func (am *AuthManager) Status() AuthStatus {
    am.mu.RLock()
    defer am.mu.RUnlock()
    ...
}
```

This is a structural change — flag for Phase 09 before any code touches `MakeAuthenticatedGmailCall` in a hot path.

## Info

### IN-01: `logInfo` in `fetchUserInfoLocked` logs the user's email address

**File:** `src/app/auth.go:328`

**Issue:** `logInfo("oauth: signed in as %s", am.email)` writes the user's email to the log file at `%TEMP%\go-mapi\native-host.log`. The D-17 constraint says userinfo must be "in-memory only, never written to disk." The log file is disk. This is a minor privacy concern (the log is local and user-accessible), but it is a D-17 boundary violation.

**Fix:**
```go
// Replace line 328:
logInfo("oauth: userinfo fetched (email present: %v)", am.email != "")
```

### IN-02: `SignedInHeader.svelte` display name prefers `email` over `name`

**File:** `src/app/frontend/src/lib/components/SignedInHeader.svelte:3`

**Issue:** `const displayName = $derived(email || name || 'your Google account')` uses email first. For users with long email addresses this truncates in the header. Most display-name conventions prefer `name` (full name) over `email` for the primary label. This is a UX issue, not a bug.

**Fix:**
```typescript
const displayName = $derived(name || email || 'your Google account');
```

### IN-03: `go.mod` declares `go 1.25.0` which is a non-existent Go release

**File:** `src/app/go.mod:3`

**Issue:** `go 1.25.0` does not exist as of 2026-04. The latest stable release is 1.24.x. This likely means the `go` directive was set speculatively or by a toolchain that auto-bumped it. While the Go toolchain accepts unknown future versions as forward-compatibility hints, it causes `go mod tidy` to warn, and `go.sum` entries may diverge on older toolchains.

**Fix:** Set to the actual minimum required version:
```
go 1.24.0
```
or whatever the oldest toolchain you intend to support is (1.21+ is sufficient for all features used here).

---

_Reviewed: 2026-04-18T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
