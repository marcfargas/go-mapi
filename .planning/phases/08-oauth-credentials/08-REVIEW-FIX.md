---
phase: 08-oauth-credentials
fixed_at: 2026-04-18T00:00:00Z
review_path: .planning/phases/08-oauth-credentials/08-REVIEW.md
iteration: 1
findings_in_scope: 5
fixed: 4
skipped: 1
status: partial
---

# Phase 08: Code Review Fix Report

**Fixed at:** 2026-04-18T00:00:00Z
**Source review:** `.planning/phases/08-oauth-credentials/08-REVIEW.md`
**Iteration:** 1

**Summary:**
- Findings in scope: 5 (1 Critical + 4 Warning)
- Fixed: 4 (CR-01, WR-01, WR-02, WR-03)
- Skipped: 1 (WR-04 — deferred to Phase 09 per reviewer note)

Info-severity findings (IN-01, IN-02, IN-03) are out of scope for this iteration and were not touched.

## Fixed Issues

### CR-01: `openBrowser` passes auth URL as unquoted rundll32 argument — command injection risk

**Files modified:** `src/app/auth.go`, `src/app/go.mod`
**Commit:** `40e32b2`
**Applied fix:** Replaced the `exec.Command("rundll32", "url.dll,FileProtocolHandler", authURL)` call with `browser.OpenURL(authURL)` from `github.com/pkg/browser`, removed the now-unused `os/exec` import, and ran `go mod tidy` in `src/app/` to promote `github.com/pkg/browser` from an indirect to a direct dependency. `go build ./...` succeeds. This removes the rundll32 surface entirely — no new transitive dependencies (pkg/browser was already in `go.sum`).

### WR-01: Double `auth-changed` emission at bootstrap races with async userinfo goroutine

**Files modified:** `src/app/auth.go`
**Commit:** `a06f320`
**Applied fix:** Removed the synchronous `a.emitAuthChanged()` call from the end of `bootstrapAuth`. The async userinfo goroutine now performs the only emission, with `email`/`name` populated. This eliminates the brief flash of an authenticated header with empty user fields. The Svelte frontend's initial pull via `GetAuthStatus()` on mount still renders the queue view correctly; the async emit updates email/name once userinfo resolves (10s worst case). `go test ./...` passes — existing bootstrap tests do not assert emission count and continue to exercise the signed-in/signed-out branches.

### WR-02: `ClearTokens` lock gap in `MakeAuthenticatedGmailCall` double-401 path

**Files modified:** `src/app/auth.go`
**Commit:** `a933ce3`
**Applied fix:** Introduced a `clearTokensLocked()` helper (mirroring the existing `saveToKeyringLocked` pattern) and refactored `MakeAuthenticatedGmailCall`'s reactive-retry branch to hold `am.refresh` across the retry `fn(token)` call AND the classify-and-clear. This eliminates the window where a concurrent caller could observe the stale access token after the refresh completes but before the second 401 is classified. The retry is bounded by `fn`'s own HTTP timeout, so the blocking window is short. `go test ./...` passes (all `MakeAuthenticatedGmailCall` tests green, including the second-401 path).

**Verification note:** This fix reviewer option (a) — stay locked across the retry — rather than option (b) which only added a locked variant. Option (a) actually closes the race; option (b) narrows but does not eliminate it.

### WR-03: `subscribeQueue` silently drops fetch errors on every queue-update event

**Files modified:** `src/app/frontend/src/lib/queue.ts`, `src/app/frontend/src/App.svelte`
**Commit:** `135a5f6`
**Applied fix:** Rewrote `subscribeQueue` to replace the swallowed-rejection `async` arrow with an explicit `.then(onChange).catch(...)` chain. The catch handler logs via `console.error('[go-mapi] queue fetch failed:', e)` and invokes an optional `onError` callback. Updated the sole caller in `App.svelte` to pass an `onError` that sets `errorMsg` to the error message (mirroring the existing `queue-error` event handler's semantics). `svelte-check` reports 0 errors (1 pre-existing a11y warning in App.svelte line 129, unrelated to this change).

## Skipped Issues

### WR-04: `signInLocked` is called while holding `am.refresh`, blocking all `Status()` reads for up to 5 minutes

**File:** `src/app/auth.go:408-425` (caller: `App.SignIn`)
**Reason:** skipped — structural change explicitly deferred to Phase 09 by reviewer ("This is a structural change — flag for Phase 09 before any code touches `MakeAuthenticatedGmailCall` in a hot path."). The proposed fix replaces `sync.Mutex` with `sync.RWMutex` for the tokens/email/name fields and retrofits every locked path (`signInLocked`, `refreshIfNeededLocked`, `ClearTokens`, `fetchUserInfoLocked`, `saveToKeyringLocked`, `revokeRefreshToken`, `MakeAuthenticatedGmailCall`, `bootstrapAuth`) to use Lock vs RLock correctly. That is an `AuthManager` API-shape change that touches the same `MakeAuthenticatedGmailCall` hot path just fixed in WR-02, and reopens audit surface across all Phase 08 tests. The struct-field comment (`// refresh sync.Mutex ... contention is impossible in practice`) will also need to be rewritten.

Applying it in this iteration would risk re-landing subtle lock-order bugs on top of an already-shipped OAuth flow. Phase 09 is the correct venue because (a) the reviewer explicitly flagged it there, and (b) Phase 09 is where draft-creation will exercise `MakeAuthenticatedGmailCall` in real hot paths, giving the refactor meaningful test coverage.

**Original issue:** `App.SignIn` acquires `a.auth.refresh.Lock()` and calls `signInLocked` which can block up to 5 minutes waiting for the browser callback. During this window, any frontend call to `GetAuthStatus()` (e.g., on re-mount after the window is hidden/shown) deadlocks on `Status()`'s own `refresh.Lock()`. In practice the contention is bounded by the 5-minute `loopbackFlowTimeout` and is only reachable if the user hides+shows the window during sign-in — narrow but real.

---

_Fixed: 2026-04-18T00:00:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
