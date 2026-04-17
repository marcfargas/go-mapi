---
phase: 08-oauth-credentials
plan: "04"
subsystem: auth
tags: [oauth, refresh, revoke, invalid_grant, startup, tray, httptest, wails-events]

dependency_graph:
  requires:
    - phase: 08-02
      provides: "AuthManager struct, OAuthTokens, saveToKeyringLocked, LoadFromKeyring, ClearTokens"
    - phase: 08-03
      provides: "signInLocked, fetchUserInfoLocked, SignIn, prepareLoopback, ErrInvalidGrant"
  provides:
    - "refreshIfNeededLocked — proactive 5-min + reactive 401 refresh with invalid_grant classification"
    - "revokeRefreshToken — best-effort 5s POST /revoke, 400 treated as idempotent success"
    - "GmailCall type + MakeAuthenticatedGmailCall — Phase 9 Gmail API wrapper with 401 retry"
    - "emitAuthChanged — nil-ctx-guarded Wails EventsEmit for auth-changed events"
    - "Real App.SignOut — revoke+clear+emit+tray (replaces Plan 03 stub)"
    - "bootstrapAuth — startup keyring load + proactive refresh + initial auth-changed emission"
    - "tokenEndpointOverride / revokeEndpointOverride — test injection points for httptest stubs"
    - "app.go OnStartup hook: a.bootstrapAuth() after tray start"
  affects:
    - "08-05 (end-to-end wiring — frontend uses GetAuthStatus + auth-changed event from bootstrapAuth)"
    - "09 (draft creation — consumes MakeAuthenticatedGmailCall wrapper)"

tech-stack:
  added:
    - "io (stdlib) — io.ReadAll for refresh response body"
    - "net/url (stdlib) — url.Values for refresh POST form, url.QueryEscape for revoke"
    - "strings (stdlib) — strings.NewReader for HTTP request bodies"
    - "net/http/httptest — httptest.NewServer for refresh/revoke stub servers in tests"
  patterns:
    - "tokenEndpointOverride / revokeEndpointOverride package vars: empty in production, set by tests with t.Cleanup reset — avoids t.Setenv (no env var needed)"
    - "refreshIfNeededLocked: fast-path nil-check + expiry-check before HTTP; error classification: 400+invalid_grant/invalid_client → ErrInvalidGrant+clear; 5xx → transient retain tokens"
    - "revokeRefreshToken: context.WithTimeout(parent, 5s) + http.Client{Timeout: 5s} — double-bounded per D-15"
    - "MakeAuthenticatedGmailCall: proactive refresh → fn(token) → 401? backdate expiry + force refresh + retry → second 401? classify ErrInvalidGrant + clear + emit"
    - "SignOut nil-ctx guard: falls back to context.Background() when a.ctx is nil (test safety)"
    - "bootstrapAuth async userinfo goroutine: emits auth-changed twice on signed-in path (once immediately, once after userinfo populates email/name)"

key-files:
  modified:
    - "src/app/auth.go — tokenEndpointOverride/revokeEndpointOverride vars, tokenEndpoint/revokeEndpoint helpers, refreshIfNeededLocked, revokeRefreshToken, GmailCall type, MakeAuthenticatedGmailCall, emitAuthChanged, real App.SignOut, bootstrapAuth"
    - "src/app/auth_test.go — 14 new tests: TestRefreshIfNeededFastPath, TestRefreshIfNeededNoTokens, TestRefreshInvalidGrantClears, TestRefreshHappyPath, TestRefreshTransient5xxRetainsTokens, TestRevoke200IsSuccess, TestRevoke400InvalidTokenTreatedAsSuccess, TestMakeAuthenticatedGmailCall_RetryOn401Succeeds, TestMakeAuthenticatedGmailCall_DoubleFailClassifiesInvalidGrant, TestSignOutEmitsAndClears, TestSignOutIdempotent, TestBootstrapAuthSignedOutPath, TestBootstrapAuthSignedInPath"
    - "src/app/app.go — a.bootstrapAuth() call at end of startup() after tray start"

key-decisions:
  - "nil ctx guard in SignOut falls back to context.Background() — revokeRefreshToken calls context.WithTimeout(parent) which panics on nil parent; test safety without live Wails runtime requires this guard. emitAuthChanged already had this guard from Task 1."
  - "tokenEndpointOverride/revokeEndpointOverride as package vars (not t.Setenv) — these are not environment variables; direct assignment + t.Cleanup reset is the correct pattern for Go test injection of non-env overrides"
  - "bootstrapAuth emits auth-changed twice on signed-in path — once immediately (so frontend gets authenticated:true quickly) and once after the async userinfo goroutine completes (so email/name populate). Second emission is non-blocking."

requirements-completed: [AUTH-03, AUTH-04, AUTH-05, AUTH-07, QUAL-03]

duration: ~15min
completed: 2026-04-18
---

# Phase 8 Plan 04: Token Refresh + Sign-Out + OnStartup Auth Bootstrap Summary

**Proactive/reactive token refresh with invalid_grant classification, best-effort revoke on sign-out, MakeAuthenticatedGmailCall Phase 9 wrapper, and startup keyring load with initial auth-changed event — Go auth layer now feature-complete**

## Performance

- **Duration:** ~15 minutes
- **Completed:** 2026-04-18
- **Tasks:** 2 (Task 1 refresh/revoke/wrapper, Task 2 SignOut/bootstrapAuth/app.go hook)
- **Files modified:** 3 (auth.go, auth_test.go, app.go)
- **Tests added:** 14 (total in suite: 50 — all passing)

## Accomplishments

- Implemented `refreshIfNeededLocked` with D-13 proactive 5-min window: fast-path (>5min), ErrNotAuthenticated (nil tokens), ErrInvalidGrant on 400 invalid_grant or invalid_client (clears tokens+keyring), transient 5xx retains tokens
- Implemented `revokeRefreshToken` with 5s context timeout + 5s http.Client timeout (double-bounded per D-15); 400 treated as idempotent success (already revoked)
- Added `tokenEndpointOverride` / `revokeEndpointOverride` package vars for httptest stub injection — no real Google endpoints hit in any test
- Implemented `GmailCall` type and `MakeAuthenticatedGmailCall` wrapper: proactive refresh → invoke fn → on 401, backdate expiry + force refresh + retry once → second 401 classifies as ErrInvalidGrant + clears + emits auth-changed
- Implemented `emitAuthChanged` with nil-ctx guard (safe without live Wails runtime)
- Replaced `App.SignOut` stub with full D-15 implementation: revoke (best-effort) + clear keyring unconditionally + clear in-memory email/name + emit auth-changed + tray error "signed out"
- Implemented `bootstrapAuth`: loads keyring → proactive refresh if needed → emits initial auth-changed (signed-out, signed-in, invalid_grant, transient-error paths all covered) → async userinfo fetch on signed-in path
- Wired `a.bootstrapAuth()` into `app.go` startup after tray is ready and `a.ctx` is cached
- All 50 tests pass; go vet clean; QUAL-03 grep clean (no token values in %v formatters)

## Task Commits

1. **Task 1: refreshIfNeededLocked + revokeRefreshToken + MakeAuthenticatedGmailCall + httptest tests** — `fecfd8a`
2. **Task 2: SignOut + bootstrapAuth + OnStartup hook + Task 2 tests** — `a447c11`

## Files Created/Modified

- `src/app/auth.go` — tokenEndpointOverride/revokeEndpointOverride + endpoint helpers; refreshIfNeededLocked; revokeRefreshToken; GmailCall type; MakeAuthenticatedGmailCall; emitAuthChanged; real App.SignOut (stub removed); bootstrapAuth
- `src/app/auth_test.go` — 14 new tests covering all refresh paths (fast-path, no-tokens, invalid_grant, happy, transient-5xx), revoke paths (200, 400-invalid_token), MakeAuthenticatedGmailCall paths (401→refresh→200, 401→invalid_grant), SignOut paths (clears+emits, idempotent), bootstrapAuth paths (signed-out, signed-in)
- `src/app/app.go` — `a.bootstrapAuth()` call added at end of `startup()` after tray and watcher are initialized

## Decisions Made

1. **nil ctx guard in SignOut** — `revokeRefreshToken` calls `context.WithTimeout(parent, 5s)` which panics on a nil parent. Tests call `app.SignOut()` without a live Wails runtime (so `a.ctx` is nil). Added `ctx := a.ctx; if ctx == nil { ctx = context.Background() }` fallback. Production path is unaffected (a.ctx is always set before SignOut is reachable in the running app). Documented as Rule 1 auto-fix.
2. **tokenEndpointOverride as package var, not t.Setenv** — The overrides are not environment variables; they're Go-level injection points. Direct assignment + `t.Cleanup(func() { tokenEndpointOverride = "" })` is the idiomatic pattern for this use case.
3. **bootstrapAuth emits auth-changed twice on signed-in path** — First emission is synchronous and immediate (frontend gets `authenticated:true` without waiting for userinfo). Second emission fires from the async userinfo goroutine and adds `email`/`name`. Both are safe because `emitAuthChanged` uses `wruntime.EventsEmit` which is concurrency-safe.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] nil parent context panic in revokeRefreshToken when a.ctx is nil**
- **Found during:** Task 2 test run (`TestSignOutEmitsAndClears`)
- **Issue:** `context.WithTimeout(parent, 5*time.Second)` panics with "cannot create context from nil parent" when `parent` is nil. Tests create `NewApp()` without a live Wails runtime, so `a.ctx` is never set (remains nil). SignOut passes `a.ctx` directly to `revokeRefreshToken`.
- **Fix:** Added nil guard in `SignOut`: `ctx := a.ctx; if ctx == nil { ctx = context.Background() }`. The 5s timeout inside `revokeRefreshToken` still applies; the guard only prevents the upstream nil panic.
- **Files modified:** `src/app/auth.go`
- **Commit:** `a447c11`

---

**Total deviations:** 1 auto-fixed (Rule 1 — bug fix)
**Impact on plan:** Strictly scoped — the guard is a test-safety fix with no effect on production behavior. Production always has `a.ctx` set before any user action can trigger SignOut.

## Known Stubs

None — this plan removes the last stub (`App.SignOut`). The Go auth layer is feature-complete.

## Threat Surface Scan

All new network surface is within the plan's threat register:
- `oauth2.googleapis.com/token` — T-08-31 (timeout: http.Client{Timeout: 15s}), T-08-30 (error field parsed, not raw body logged), T-08-32 (system CA pool)
- `oauth2.googleapis.com/revoke` — T-08-33 (SignOut returns nil only after keyring.Delete completes; emitAuthChanged fires), T-08-31 (5s timeout)
- T-08-34 covered: second 401 after refresh explicitly classified as ErrInvalidGrant in MakeAuthenticatedGmailCall, proven by TestMakeAuthenticatedGmailCall_DoubleFailClassifiesInvalidGrant
- T-08-35 covered: refresh_token updated only when non-empty in response

No new network endpoints, file access patterns, or schema changes outside the plan's threat register.

## Self-Check: PASSED

- `src/app/auth.go` — FOUND; contains `refreshIfNeededLocked` (line 453), `revokeRefreshToken` (line 535), `MakeAuthenticatedGmailCall` (line 577), `emitAuthChanged` (line 631), `invalid_grant` (line 488), `invalid_client` (line 488), `tokenEndpointOverride` (line 430), `revokeEndpointOverride` (line 431), `bootstrapAuth` (line 674), `SignOut not implemented` — NOT FOUND (stub removed)
- `src/app/auth_test.go` — FOUND; contains `TestMakeAuthenticatedGmailCall_RetryOn401Succeeds` (line 415), `TestMakeAuthenticatedGmailCall_DoubleFailClassifiesInvalidGrant` (line 469), `TestRefreshInvalidGrantClears` (line 299), `TestSignOutEmitsAndClears` (line 513), `TestBootstrapAuthSignedInPath` (line 565)
- `src/app/app.go` — FOUND; contains `a.bootstrapAuth()` (line 102)
- Commit `fecfd8a` (Task 1) — FOUND
- Commit `a447c11` (Task 2) — FOUND
- `go test -count=1 ./...` in `src/app` — PASSED (50 tests, 0.788s)
- `go vet ./...` — PASSED (no output)
- QUAL-03 grep — PASSED (no token internals in %v formatters in production code)
- Key acceptance criteria greps — ALL PASSED
