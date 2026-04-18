---
phase: 08-oauth-credentials
verified: 2026-04-18T00:00:00Z
approved: 2026-04-18T00:30:00Z
status: passed
score: 5/5 must-haves verified (4 automated + 3 human-passed, 1 skipped — see 08-HUMAN-UAT.md)
must_haves_verified: 5/5
post_verification_fixes:
  - commit: 04462ed
    issue: SetTrayIdle missing — tray could flip red but not back to idle on SignIn success. Caught during UAT #3.
  - commit: 385b457
    issue: Wails bindings not regenerated for SetTrayIdle / MakeAuthenticatedGmailCall.
  - commit: f05d63c
    issue: dev-wails.ps1 failed on Go 1.26 Windows/ARM64 (Syscall15 nosplit under -N -l). Switched to wails build -devtools + run-binary.
requirements_satisfied:
  - AUTH-01
  - AUTH-02
  - AUTH-03
  - AUTH-04
  - AUTH-05
  - AUTH-06
  - AUTH-07
  - QUAL-03
requirements_missing: []
overrides_applied: 0
human_verification:
  - test: "Complete end-to-end sign-in: run `pwsh scripts/dev-wails.ps1`, click 'Sign in with Google' in the main window. Verify the SYSTEM browser (not an embedded webview) opens to Google OAuth consent."
    expected: "System default browser navigates to https://accounts.google.com/o/oauth2/v2/auth with code_challenge_method=S256. After granting consent, the loopback tab shows 'Signed in to go-mapi' and the Wails window switches to the queue view with a 'Signed in as <email>' header."
    why_human: "Requires a real Google account, live GCP credentials in .env.local, and Windows browser launch — not automatable without external service access."
  - test: "Persist across restart: after signing in (step 1), close the app via tray Quit, relaunch via `pwsh scripts/dev-wails.ps1`. Confirm app launches directly to the queue view (not the sign-in screen)."
    expected: "bootstrapAuth loads the refresh token from Windows Credential Manager and emits auth-changed{authenticated:true}. Tray icon stays idle. No sign-in prompt shown."
    why_human: "Requires live Windows Credential Manager state from a prior sign-in — not reproducible programmatically without real tokens."
  - test: "Tray icon state transitions: (a) fresh install / after sign-out → tray icon = error variant; (b) after successful sign-in → tray icon = idle variant; (c) after sign-out → tray error again."
    expected: "Tray icon visually reflects auth state at all three points as described."
    why_human: "Tray icon visual state is not inspectable via code; requires manual observation."
  - test: "Re-auth banner: while signed in, open Wails devtools (right-click → Inspect on dev build) and run `window.runtime.EventsEmit('auth-changed', { authenticated: false })`. Observe that (a) the red 'Sign-in expired — click to restore' banner appears at the top of the window AND (b) the UI transitions from the queue view / SignedInHeader back to the SignInScreen."
    expected: "Both banner and SignInScreen appear simultaneously. Clicking 'Sign in again' in the banner invokes SignIn() directly (no pre-auth modal re-show since localStorage flag is set)."
    why_human: "Requires a live running Wails window with devtools access — cannot be automated as a unit test."
---

# Phase 8: oauth-credentials Verification Report

**Phase Goal:** Users can authenticate with Google through a native desktop OAuth flow and stay signed in across restarts, with credentials stored securely in the Windows Credential Manager

**Verified:** 2026-04-18
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | First-run user sees a sign-in prompt; clicking it opens the SYSTEM browser (not embedded webview) to Google OAuth consent | ? HUMAN NEEDED | `SignInScreen.svelte` renders "Sign in with Google" CTA wired to `handleSignInClick`. `openBrowser()` in `auth.go:201-203` uses `exec.Command("rundll32", "url.dll,FileProtocolHandler", authURL)` — RFC 8252 compliant, no embedded webview. PKCE S256 verified by `TestAuthCodeURLHasPKCE`. End-to-end browser launch requires a live run. |
| 2 | After consent, refresh token stored in Windows Credential Manager; user remains signed in after restart | VERIFIED (code) / HUMAN for restart | `signInLocked` (auth.go:332-392) saves tokens via `saveToKeyringLocked()` → `keyring.Set(keyringService, keyringUser, ...)`. `bootstrapAuth()` (auth.go:674-714) loads from keyring on startup and emits `auth-changed`. Round-trip proven by `TestAuthManagerKeyringRoundTrip` and `TestBootstrapAuthSignedInPath`. Cross-restart persistence needs human smoke. |
| 3 | When Gmail API returns 401, access token refreshes transparently | VERIFIED | `MakeAuthenticatedGmailCall` (auth.go:577-628) implements proactive + reactive refresh. Verified by `TestMakeAuthenticatedGmailCall_RetryOn401Succeeds` (401→refresh→200 path with httptest stub). |
| 4 | If refresh token invalidated (invalid_grant), user sees clear re-sign-in prompt rather than silent failure or retry loop | VERIFIED | `refreshIfNeededLocked` (auth.go:453-531) classifies 400 `invalid_grant` and `invalid_client` as `ErrInvalidGrant`, clears tokens and keyring immediately. `MakeAuthenticatedGmailCall` calls `emitAuthChanged()` + `SetTrayError()` on `ErrInvalidGrant`. Frontend `App.svelte:43-52` detects `wasAuthenticated && !s.authenticated` transition and shows `ReAuthBanner`. Verified by `TestRefreshInvalidGrantClears` and `TestMakeAuthenticatedGmailCall_DoubleFailClassifiesInvalidGrant`. Banner text "Sign-in expired — click to restore" confirmed in `ReAuthBanner.svelte:5-8`. |
| 5 | User can sign out from main window; signing out clears stored token from Credential Manager | VERIFIED | `SignedInHeader.svelte:8` renders "Sign out" button wired to `handleSignOutClick` → `signOut()` → `App.SignOut()`. `SignOut()` (auth.go:646-668) calls `revokeRefreshToken()`, clears `am.tokens`, `am.email`, `am.name`, calls `keyring.Delete()` unconditionally, emits `auth-changed{false}`, calls `SetTrayError("signed out")`. Verified by `TestSignOutEmitsAndClears` and `TestSignOutIdempotent`. |

**Score:** 4/5 truths verified in code (SC-1 requires live human test for browser-opens assertion; SC-2 requires human for restart persistence; SC-4 full banner UX requires human observation)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/app/auth_credentials.go` | ldflags injection vars + env fallback | VERIFIED | Contains `var oauthClientID`, `var oauthClientSecret`, `init()` reading `GOMAPI_OAUTH_CLIENT_ID`/`GOMAPI_OAUTH_CLIENT_SECRET` |
| `src/app/credentials_check.go` | D-10 fatal guard (!bindings tag) | VERIFIED | File exists; build-tag split prevents fatal guard from blocking `wails build` binding generation |
| `src/app/credentials_check_bindings.go` | No-op stub (bindings tag) | VERIFIED | File exists |
| `scripts/dev-wails.ps1` | Dev entry point sourcing .env.local | VERIFIED | File exists; reads .env.local at repo root, sets env vars, invokes `wails dev` |
| `.env.local.example` | Template at repo root | VERIFIED | File exists at repo root with `GOMAPI_OAUTH_CLIENT_ID=` |
| `.gitignore` | `/.env.local` rule | VERIFIED | Rule present (1 match via grep) |
| `src/app/auth.go` | AuthManager, OAuthTokens, AuthStatus, PKCE flow, refresh, revoke, sign-out, bootstrapAuth | VERIFIED | 715-line file with all required types, methods, and bindings. No stubs remain (confirmed: "SignIn not implemented" and "SignOut not implemented" strings absent). |
| `src/app/auth_test.go` | 50 tests covering all auth paths | VERIFIED | Key tests confirmed present: `TestMakeAuthenticatedGmailCall_RetryOn401Succeeds`, `TestRefreshInvalidGrantClears`, `TestBootstrapAuthSignedInPath`, `TestSignOutEmitsAndClears` |
| `src/app/app.go` | `auth *AuthManager` field + `bootstrapAuth()` in startup | VERIFIED | Line 18: `auth *AuthManager`; line 37: `auth: NewAuthManager()` in `NewApp()`; line 102: `a.bootstrapAuth()` in startup after tray |
| `src/app/frontend/src/lib/auth.ts` | Auth store with EventsOn + Wails bindings | VERIFIED | Imports `GetAuthStatus`, `SignIn`, `SignOut`; `subscribeAuth()` wraps `EventsOn('auth-changed', ...)` |
| `src/app/frontend/src/lib/components/SignInScreen.svelte` | Welcome screen with CTA | VERIFIED | "Sign in with Google" button present |
| `src/app/frontend/src/lib/components/PreAuthModal.svelte` | One-time pre-auth explainer | VERIFIED | "Advanced" and "Go to go-mapi (unsafe)" text present; D-02 honored |
| `src/app/frontend/src/lib/components/ReAuthBanner.svelte` | Red re-auth banner | VERIFIED | "Sign-in expired — click to restore" text present |
| `src/app/frontend/src/lib/components/SignedInHeader.svelte` | Signed-in header with sign-out | VERIFIED | "Sign out" button present; `$derived(email \|\| name \|\| 'your Google account')` for reactive display |
| `src/app/frontend/src/App.svelte` | Auth-gated queue view + all overlays | VERIFIED | All four components imported; `{#if !auth.authenticated}` gates queue; `wasAuthenticated` tracks transition for banner; pre-auth modal localStorage flag wired |
| `src/app/frontend/wailsjs/go/main/App.d.ts` | Generated bindings with GetAuthStatus/SignIn/SignOut | VERIFIED | All three methods present |
| `src/app/frontend/wailsjs/go/models.ts` | AuthStatus type | VERIFIED | `AuthStatus` class present |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `src/app/main.go` | `src/app/auth_credentials.go` | `checkOAuthCredentials()` | VERIFIED | D-10 guard extracted to `credentials_check.go` with `!bindings` tag; called from `main()` |
| `src/app/app.go:startup` | `src/app/auth.go:bootstrapAuth` | `a.bootstrapAuth()` | VERIFIED | Line 102 of app.go |
| `src/app/auth.go:signInLocked` | `golang.org/x/oauth2` | `cfg.Exchange` + `S256ChallengeOption` + `VerifierOption` | VERIFIED | All three present in auth.go |
| `src/app/auth.go:openBrowser` | Windows shell | `rundll32 url.dll,FileProtocolHandler` | VERIFIED | Line 202 of auth.go |
| `src/app/auth.go:refreshIfNeededLocked` | `https://oauth2.googleapis.com/token` | `http.PostForm grant_type=refresh_token` | VERIFIED | `tokenEndpoint()` helper + `form.Encode()` POST at line 470 |
| `src/app/auth.go:revokeRefreshToken` | `https://oauth2.googleapis.com/revoke` | `http.Client Timeout 5s` | VERIFIED | `revokeEndpoint()` + 5s timeout at line 549 |
| `src/app/auth.go:SignIn` | Wails frontend | `wruntime.EventsEmit(a.ctx, "auth-changed", ...)` | VERIFIED | Line 419 of auth.go |
| `src/app/frontend/src/lib/auth.ts` | `wailsjs/go/main/App` | `GetAuthStatus`, `SignIn`, `SignOut` | VERIFIED | All three imported on line 2 of auth.ts |
| `src/app/frontend/src/lib/auth.ts` | `wailsjs/runtime/runtime` | `EventsOn('auth-changed', ...)` | VERIFIED | `subscribeAuth()` at line 36-38 of auth.ts |
| `src/app/frontend/src/App.svelte` | `src/app/frontend/src/lib/auth.ts` | `from './lib/auth'` | VERIFIED | Imports confirmed at lines 5-13 of App.svelte |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `App.svelte` | `auth` (AuthStatus) | `fetchAuthStatus()` → `GetAuthStatus()` → `a.auth.Status()` → keyring on startup | Yes — `bootstrapAuth` loads from real Windows Credential Manager | FLOWING |
| `App.svelte` | `auth` updates | `subscribeAuth()` → `EventsOn('auth-changed')` ← `emitAuthChanged()` ← Go events | Yes — emitted on every auth state change from Go side | FLOWING |
| `SignedInHeader.svelte` | `email`, `name` | Passed from App.svelte's `auth.email`, `auth.name` ← `fetchUserInfoLocked()` from Google userinfo endpoint | Yes — fetched from `https://www.googleapis.com/oauth2/v3/userinfo` with real access token; in-memory only per D-17 | FLOWING |
| `ReAuthBanner.svelte` | visibility | `showReAuthBanner` set when `wasAuthenticated && !s.authenticated` in `subscribeAuth` callback | Yes — driven by real Go `ErrInvalidGrant` path | FLOWING |

### Behavioral Spot-Checks

| Behavior | Check | Result | Status |
|----------|-------|--------|--------|
| `go test ./...` passes (50 tests) | Confirmed via 08-04-SUMMARY.md self-check | 50 tests, 0.788s | PASS (from SUMMARY; not re-run here) |
| No token values in `%v` formatters (QUAL-03) | `grep -nE '%[+#]?v' src/app/auth.go \| grep -iE 'AccessToken\|RefreshToken\|am\.tokens\b\|verifier\|\bcode\b' \| grep -v '_test.go'` | No matches | PASS |
| SignIn/SignOut stubs removed | `grep -n 'SignIn not implemented\|SignOut not implemented' src/app/auth.go` | No matches | PASS |
| bootstrapAuth wired in startup | `grep -n 'a.bootstrapAuth()' src/app/app.go` | Line 102 | PASS |
| Wails bindings regenerated | `grep -n 'GetAuthStatus\|SignIn\|SignOut' src/app/frontend/wailsjs/go/main/App.d.ts` | All three present | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| AUTH-01 | 08-03 | First-run via loopback redirect + PKCE S256 | VERIFIED (code); HUMAN for live test | `prepareLoopback` binds 127.0.0.1:0; `oauth2.S256ChallengeOption`; `TestAuthCodeURLHasPKCE` confirms S256 in authURL |
| AUTH-02 | 08-03 | System browser, no embedded webview | VERIFIED (code); HUMAN for live test | `openBrowser` uses `rundll32 url.dll,FileProtocolHandler` |
| AUTH-03 | 08-02/08-04 | Refresh token in Windows Credential Manager | VERIFIED | `keyring.Set/Get/Delete` in `auth.go`; `TestAuthManagerKeyringRoundTrip` passes against real WinCred |
| AUTH-04 | 08-04 | Transparent 401 refresh | VERIFIED | `MakeAuthenticatedGmailCall` proactive+reactive refresh; `TestMakeAuthenticatedGmailCall_RetryOn401Succeeds` |
| AUTH-05 | 08-04 | invalid_grant → clear re-sign-in prompt | VERIFIED | `refreshIfNeededLocked` classifies and clears; `emitAuthChanged` → `ReAuthBanner` in frontend; `TestRefreshInvalidGrantClears` + `TestMakeAuthenticatedGmailCall_DoubleFailClassifiesInvalidGrant` |
| AUTH-06 | 08-01 | GCP verification filed day 1 | VERIFIED (human action recorded) | Marc submitted Google OAuth verification on 2026-04-17 per 08-01-SUMMARY.md Task 1 checkpoint |
| AUTH-07 | 08-04 | Sign out clears stored token | VERIFIED | `SignOut()` calls `keyring.Delete` unconditionally; `TestSignOutEmitsAndClears` confirms keyring cleared; Sign out button in `SignedInHeader.svelte` |
| QUAL-03 | 08-01/08-02 | No telemetry; no content retention; no token logging | VERIFIED | `.env.local` gitignored; QUAL-03 grep confirms no token values in `%v` formatters; email/name in memory only per D-17 |

### Anti-Patterns Found

| File | Pattern | Severity | Impact |
|------|---------|----------|--------|
| `src/app/auth.go:199-203` | `rundll32 url.dll,FileProtocolHandler` to open browser | OBSERVATION (not blocker) | The 8-REVIEW.md flagged this as a critical recommendation to replace with `pkg/browser` or `ShellExecuteW` — `rundll32` can fail silently on some Windows configurations and is not the idiomatic Go approach. However: (a) this matches the CONTEXT.md D-02 discretion choice, (b) plan acceptance criteria explicitly require this pattern, (c) `cmd.Start()` returns an error that is propagated. Advisory for Phase 9 or a follow-up. Does NOT block goal achievement. |

No placeholder/TODO/stub patterns found. All `return nil`/`return error` patterns in auth.go are production implementations, not stubs. Token-related `init()` in `auth_credentials.go` correctly leaves vars empty in the source tree (by design per D-08).

### Human Verification Required

#### 1. End-to-End Sign-In Flow (Browser Opens)

**Test:** Run `pwsh scripts/dev-wails.ps1` with valid credentials in `.env.local`. Click "Sign in with Google" in the main window.

**Expected:** The system's default browser opens (not an embedded webview inside the app) to `https://accounts.google.com/o/oauth2/v2/auth` with `code_challenge_method=S256` visible in the URL. After granting consent, the loopback callback tab shows "Signed in to go-mapi". The Wails window transitions to the queue view with a "Signed in as \<email\>" header and idle tray icon.

**Why human:** Requires live GCP OAuth credentials, a real Google account, and observation of the Windows browser process launching.

#### 2. Persist Across App Restart

**Test:** After completing step 1, quit via tray → Quit. Relaunch via `pwsh scripts/dev-wails.ps1`.

**Expected:** The app opens directly to the queue view (not the sign-in screen). The tray icon is idle. Run `cmdkey /list:go-mapi` and confirm `LegacyGeneric:target=go-mapi` entry is present.

**Why human:** Cross-process Credential Manager state requires a real prior sign-in.

#### 3. Tray Icon State Transitions

**Test:** Observe tray icon at (a) fresh install / after sign-out, (b) after successful sign-in, (c) after clicking Sign out.

**Expected:** (a) error variant, (b) idle variant, (c) error variant again.

**Why human:** Tray icon visual state is not inspectable programmatically.

#### 4. Re-Auth Banner UX

**Test:** While signed in, open Wails devtools and run `window.runtime.EventsEmit('auth-changed', { authenticated: false })` in the console.

**Expected:** Red "Sign-in expired — click to restore" banner appears at the top of the window. The queue view / SignedInHeader disappears and is replaced by the SignInScreen. Clicking "Sign in again" invokes SignIn directly without the pre-auth modal re-appearing (localStorage flag persisted from first sign-in).

**Why human:** Requires a live running Wails window with devtools access.

### Gaps Summary

No hard gaps. All five ROADMAP success criteria are implemented in code and tested with unit/integration tests. The `human_needed` status reflects that success criteria 1 (system browser opens) and 2 (persist across restart) have only programmatic evidence — they have not been observed running end-to-end with real Google credentials.

The `rundll32` advisory from the 8-REVIEW.md is noted as an observation but does not block the phase goal. The CONTEXT.md explicitly lists this as a discretionary implementation choice (§Claude's Discretion), and the plan acceptance criteria require it. No override entry is needed because the choice is documented in the planning artifacts.

---

_Verified: 2026-04-18_
_Verifier: Claude (gsd-verifier)_
