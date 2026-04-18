---
status: resolved
phase: 08-oauth-credentials
source: [08-VERIFICATION.md]
started: 2026-04-18T00:00:00Z
updated: 2026-04-18T00:30:00Z
---

## Current Test

[complete]

## Tests

### 1. End-to-end sign-in via system browser
expected: System default browser opens to https://accounts.google.com/o/oauth2/v2/auth with code_challenge_method=S256. After granting consent, the loopback tab shows "Signed in to go-mapi" and the Wails window switches to the queue view with a "Signed in as <email>" header.
result: passed

### 2. Persistence across restart
expected: After signing in once, quit via tray Quit, relaunch via `pwsh scripts/dev-wails.ps1`. App launches directly to queue view (not the sign-in screen). bootstrapAuth loads the refresh token from Windows Credential Manager and emits auth-changed{authenticated:true}. Tray icon stays idle.
result: passed

### 3. Tray icon state transitions
expected: (a) fresh install / after sign-out → tray icon = error variant; (b) after successful sign-in → tray icon = idle variant; (c) after sign-out → tray error again.
result: passed-after-fix
note: SignOut correctly flipped tray to error, but SignIn did not flip back — caught during UAT. Fixed by adding SetTrayIdle and wiring it into App.SignIn and bootstrapAuth success paths (commits 04462ed + 385b457).

### 4. Re-auth banner on mid-session expiry
expected: With app signed in, opening Wails devtools and emitting `window.runtime.EventsEmit('auth-changed', { authenticated: false })` causes (a) the red "Sign-in expired — click to restore" banner to appear AND (b) the UI to transition from queue/SignedInHeader back to SignInScreen. Clicking "Sign in again" invokes SignIn() directly with no pre-auth modal re-show.
result: skipped
note: F12 / Ctrl+Shift+I devtools didn't open on this machine even with `wails build -devtools` flag. Deferred — addressable via `options.Debug{OpenInspectorOnStartup: true}` in main.go when needed.

## Summary

total: 4
passed: 3
issues: 0
pending: 0
skipped: 1
blocked: 0

## Side findings (fixed inline)

- **Build-error blocker**: `wails dev` / `wails build -debug` fail on Go 1.26 Windows/ARM64 with `syscall.Syscall15: nosplit stack over 792 byte limit` under `-gcflags "all=-N -l"`. `dev-wails.ps1` switched to `wails build -devtools` + run-binary pattern (no hot reload). Commit f05d63c. Upstream Go bug, not phase 08 code.
- **Tray-idle gap**: `SetTrayIdle` helper was missing — tray could flip red but never flip back to idle after a successful sign-in. Fixed in 04462ed + 385b457.

## Gaps

(none)
