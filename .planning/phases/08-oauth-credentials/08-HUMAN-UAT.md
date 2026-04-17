---
status: partial
phase: 08-oauth-credentials
source: [08-VERIFICATION.md]
started: 2026-04-18T00:00:00Z
updated: 2026-04-18T00:00:00Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. End-to-end sign-in via system browser
expected: System default browser opens to https://accounts.google.com/o/oauth2/v2/auth with code_challenge_method=S256. After granting consent, the loopback tab shows "Signed in to go-mapi" and the Wails window switches to the queue view with a "Signed in as <email>" header.
result: [pending]

### 2. Persistence across restart
expected: After signing in once, quit via tray Quit, relaunch via `pwsh scripts/dev-wails.ps1`. App launches directly to queue view (not the sign-in screen). bootstrapAuth loads the refresh token from Windows Credential Manager and emits auth-changed{authenticated:true}. Tray icon stays idle.
result: [pending]

### 3. Tray icon state transitions
expected: (a) fresh install / after sign-out → tray icon = error variant; (b) after successful sign-in → tray icon = idle variant; (c) after sign-out → tray error again.
result: [pending]

### 4. Re-auth banner on mid-session expiry
expected: With app signed in, opening Wails devtools and emitting `window.runtime.EventsEmit('auth-changed', { authenticated: false })` causes (a) the red "Sign-in expired — click to restore" banner to appear AND (b) the UI to transition from queue/SignedInHeader back to SignInScreen. Clicking "Sign in again" invokes SignIn() directly with no pre-auth modal re-show.
result: [pending]

## Summary

total: 4
passed: 0
issues: 0
pending: 4
skipped: 0
blocked: 0

## Gaps
