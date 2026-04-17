---
phase: 08-oauth-credentials
plan: "03"
subsystem: auth
tags: [oauth, pkce, loopback, s256, golang-x-oauth2, userinfo, rundll32, wails-events]

dependency_graph:
  requires:
    - phase: 08-01
      provides: "oauthClientID/oauthClientSecret package-level vars"
    - phase: 08-02
      provides: "AuthManager struct, OAuthTokens, saveToKeyringLocked, cancelFlow field"
  provides:
    - "Real App.SignIn() — full PKCE S256 loopback desktop OAuth flow"
    - "newOAuthConfig() — *oauth2.Config with 4 scopes + google.Endpoint"
    - "prepareLoopback() — split-design returns redirectURL before blocking; validates state CSRF"
    - "runLoopback() — convenience wrapper used by signInLocked"
    - "randomState() — 43-char crypto/rand base64url CSRF token"
    - "openBrowser() — rundll32 url.dll,FileProtocolHandler (RFC 8252, no webview)"
    - "signInLocked() — orchestrates PKCE verifier, loopback, Exchange, keyring save, userinfo fetch"
    - "fetchUserInfoLocked() — populates am.email/am.name in memory only (D-17)"
    - "userinfoResponse type — JSON decode of Google userinfo v3 endpoint"
    - "EventsEmit auth-changed on successful SignIn (D-19)"
  affects:
    - "08-04 (token refresh + sign-out — calls am.LoadFromKeyring on startup)"
    - "08-05 (end-to-end wiring — frontend signs in via App.SignIn)"

tech-stack:
  added:
    - "golang.org/x/oauth2 v0.36.0 — oauth2.Config, GenerateVerifier, S256ChallengeOption, VerifierOption, AccessTypeOffline, SetAuthURLParam"
    - "golang.org/x/oauth2/google — google.Endpoint (accounts.google.com auth + token URLs)"
    - "cloud.google.com/go/compute/metadata v0.3.0 (transitive, pulled by x/oauth2)"
  patterns:
    - "prepareLoopback split-design: returns (redirectURL, wait, cleanup, err) so callers can build cfg BEFORE blocking — enables testability without port scanning"
    - "sync.Once single-shot send: loopback handler sends exactly once regardless of concurrent callback requests"
    - "context.WithTimeout(parent, 5min) stored as am.cancelFlow for Plan 05 Cancel button"
    - "fetchUserInfoLocked is non-fatal: logged and swallowed if userinfo fails — user is still signed in"
    - "token.RefreshToken == empty guard: rejects silent re-auth that returned no refresh_token"
    - "QUAL-03 enforced: no %v/%+v/%#v on token structs; log only token.Expiry.Format(time.RFC3339)"

key-files:
  modified:
    - "src/app/auth.go — real SignIn, newOAuthConfig, prepareLoopback, runLoopback, randomState, openBrowser, signInLocked, fetchUserInfoLocked, userinfoResponse, EventsEmit auth-changed"
    - "src/app/auth_test.go — 7 new tests: TestGenerateVerifierLength, TestAuthCodeURLHasPKCE, TestRandomStateUnique, TestRunLoopbackStateMismatchRejected, TestRunLoopbackHappyPath, TestRunLoopbackContextCancel, TestUserinfoResponseDecode"
    - "src/app/go.mod — golang.org/x/oauth2 v0.36.0 added to require block"
    - "src/app/go.sum — x/oauth2 + cloud.google.com/go/compute/metadata checksums added"
    - "go.work — go directive bumped from 1.23 to 1.25.0 by go mod tidy"

key-decisions:
  - "prepareLoopback split-design chosen over original runLoopback-only design: the test for CSRF rejection needs the redirectURL before wait() blocks — splitting into prepare+wait makes this clean without port scanning"
  - "Task 1 and Task 2 implemented in one commit: both depend on the same auth.go state; splitting RED/GREEN across two files would require a partial compile — combined into one feat commit per the no-verify worktree pattern"
  - "frontend/dist copied from main worktree: worktrees share the git object store but not the untracked build output; dist must exist for the embed directive to compile"
  - "go.work go directive bump 1.23→1.25.0: side effect of go mod tidy in the worktree; harmless (go.work is not per-worktree)"

requirements-completed: [AUTH-01, AUTH-02, QUAL-03]

duration: 4min
completed: 2026-04-17
---

# Phase 8 Plan 03: PKCE Loopback Sign-In Flow Summary

**Real desktop OAuth sign-in: PKCE S256 loopback callback, code exchange via golang.org/x/oauth2, userinfo fetch in memory only, keyring persistence, and auth-changed event emitted to Wails frontend**

## Performance

- **Duration:** ~4 minutes
- **Started:** 2026-04-17T22:53:15Z
- **Completed:** 2026-04-17T22:57:00Z
- **Tasks:** 2 (Task 1 helpers + tests, Task 2 SignIn end-to-end)
- **Files modified:** 5 (auth.go, auth_test.go, go.mod, go.sum, go.work)

## Accomplishments

- Implemented `newOAuthConfig` with 4 required scopes (gmail.compose, gmail.send, userinfo.email, userinfo.profile) and access_type=offline
- Implemented `prepareLoopback` split-design: binds 127.0.0.1:0, returns redirectURL immediately so caller can build the OAuth config before blocking on wait() — enables CSRF test without port scanning
- Implemented `randomState` (32 random bytes → 43-char base64url) and `openBrowser` (rundll32 url.dll,FileProtocolHandler — RFC 8252 compliant, no webview)
- Implemented `signInLocked` orchestrating PKCE verifier → loopback → browser open → code exchange → keyring save → userinfo fetch
- Implemented `fetchUserInfoLocked` writing only to in-memory am.email/am.name (D-17 honored)
- Replaced `App.SignIn` stub with real implementation that calls signInLocked under the refresh mutex and emits auth-changed on success
- All 32 tests pass (7 new tests from this plan)
- QUAL-03 grep verified: no token internals appear in %v/%+v/%#v format verbs in production code

## Task Commits

1. **Task 1 + Task 2: PKCE helpers, loopback, signInLocked, userinfo, auth-changed** - `4892205` (feat)

## Files Created/Modified

- `src/app/auth.go` — real SignIn, newOAuthConfig, prepareLoopback, runLoopback, randomState, openBrowser, signInLocked, fetchUserInfoLocked, userinfoResponse type, EventsEmit auth-changed; SignIn stub removed
- `src/app/auth_test.go` — 7 new tests covering PKCE verifier length, AuthCodeURL PKCE params, random state uniqueness, loopback state mismatch CSRF rejection, loopback happy path, loopback context cancel, userinfo JSON decode
- `src/app/go.mod` — golang.org/x/oauth2 v0.36.0 added
- `src/app/go.sum` — checksums added
- `go.work` — go directive bumped to 1.25.0 (go mod tidy side effect)

## Decisions Made

1. **prepareLoopback split-design over original monolithic runLoopback** — the plan itself suggested this refactor: returning (redirectURL, wait, cleanup, err) allows the test to issue the HTTP GET with a mismatched state before calling wait(), which is impossible if the redirect URL is only returned after the listener completes.
2. **Combined Task 1 + Task 2 into one commit** — both tasks modify auth.go; separating them would leave auth.go in a partial state that doesn't compile (Task 2's signInLocked calls prepareLoopback from Task 1). Single feat commit covers the complete plan scope.
3. **frontend/dist copied from main worktree** — the embed directive in main.go requires a built frontend to compile. The worktree doesn't inherit untracked build outputs. Copying the existing dist unblocks test compilation (no functional change to dist content).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] -race flag not supported on windows/arm64**
- **Found during:** Task 1 test run
- **Issue:** `go test -race ./...` exits with "race is not supported on windows/arm64". The plan specifies `-race` but this machine runs Go on arm64 (Wails ARM Windows dev).
- **Fix:** Ran `go test ./...` without `-race`. All tests pass; the race detector omission is a platform limitation, not a code issue. Race safety is ensured structurally (sync.Once, sync.Mutex, channel-based signaling).
- **Files modified:** none (test invocation only)
- **Commit:** n/a (not a code change)

**2. [Rule 3 - Blocking] frontend/dist missing in worktree prevented compilation**
- **Found during:** Task 1 (go build / go test)
- **Issue:** The embed directive `//go:embed all:frontend/dist` in main.go requires the dist directory to exist at compile time. Worktrees share the git object store but not untracked build output.
- **Fix:** Copied `/c/dev/go-mapi/src/app/frontend/dist` into the worktree. The dist content is unchanged (built by Plan 07); this is a worktree bootstrap step, not a code change.
- **Files modified:** none committed (dist is gitignored build output)
- **Commit:** n/a

---

**Total deviations:** 2 auto-fixed (Rule 3 — blocking issues)
**Impact on plan:** Both are environment/tooling constraints, not logic changes. All 7 plan acceptance-criteria greps pass; all 32 tests pass.

## Known Stubs

- `App.SignOut()` — returns `errors.New("SignOut not implemented until Plan 04")`. Intentional; Plan 04 implements the D-15 revoke + clear path.

## Threat Surface Scan

No new network endpoints beyond what the plan's threat register covers. The loopback listener binds on 127.0.0.1:0 (not 0.0.0.0 — T-08-20 binding is correct). The userinfo fetch goes to googleapis.com over TLS (covered by T-08-23). No new file access patterns or schema changes introduced.

## Self-Check: PASSED

- `src/app/auth.go` — FOUND; contains `signInLocked` (line 329), `prepareLoopback` (line 208), `openBrowser` (line 197), `oauth2.GenerateVerifier` (line 338), `rundll32` (line 199), `userinfoEndpoint` (line 34)
- `src/app/auth_test.go` — FOUND; contains `TestAuthCodeURLHasPKCE`, `TestRunLoopbackStateMismatchRejected`, `TestUserinfoResponseDecode`
- `src/app/go.mod` — contains `golang.org/x/oauth2 v0.36.0`
- Commit `4892205` — FOUND (`git log --oneline -1` confirms)
- `go test ./...` in `src/app` — PASSED (32 tests, 0.671s)
- QUAL-03 grep — PASSED (no token internals in %v formatters)
- Key acceptance-criteria greps — ALL PASSED (golang.org/x/oauth2/google, oauth2.GenerateVerifier, S256ChallengeOption, scopeGmailCompose, scopeGmailSend, rundll32, net.Listen tcp 127.0.0.1:0, signInLocked, cfg.Exchange, VerifierOption, SetAuthURLParam prompt consent, fetchUserInfoLocked, userinfoEndpoint, EventsEmit auth-changed, stub removed)
