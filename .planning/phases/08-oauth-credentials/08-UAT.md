---
status: complete
phase: 08-oauth-credentials
source: [08-REVIEW-FIX.md, 08-05-SUMMARY.md, 08-04-SUMMARY.md]
started: 2026-04-18T12:30:37Z
updated: 2026-04-18T12:40:00Z
context: |
  Post code-review-fix regression pass. Phase 08 was previously verified
  (08-HUMAN-UAT.md, 08-VERIFICATION.md — status: passed). Four fixes were
  applied in commits 40e32b2, a06f320, a933ce3, 135a5f6 touching the OAuth
  sign-in flow and queue subscribe path. This UAT re-tests the
  user-observable behaviour those fixes could have regressed.
---

## Current Test

[testing complete]

## Tests

### 1. Cold start smoke (signed-in persistence + single emit)
expected: |
  From a state where you've signed in before (Credential Manager contains
  `go-mapi` entry), run `pwsh scripts/dev-wails.ps1`. The app should boot
  directly into the queue view (not SignInScreen), with the signed-in
  header showing your name or email. You should NOT see a brief flash of
  the header rendering without email/name before it populates (that flash
  was WR-01 — fixed so there is exactly one auth-changed emit with
  populated fields). Tray icon should be the idle variant throughout.
result: pass

### 2. Sign-in opens system browser via pkg/browser
expected: |
  From a signed-out state (sign out first via the header button if needed,
  then quit and relaunch), click "Sign in with Google" on SignInScreen.
  System default browser should open to
  `https://accounts.google.com/o/oauth2/v2/auth` with
  `code_challenge_method=S256` in the URL (this is now routed through
  `github.com/pkg/browser` instead of `rundll32 url.dll,...` — CR-01). No
  console window should flash. After granting consent the loopback tab
  shows "Signed in to go-mapi" and the Wails window switches to the
  queue view. Tray flips to idle.
result: pass

### 3. Queue events propagate and errors surface (WR-03)
expected: |
  While signed in and idle on the queue view, drop a valid test email
  JSON into `%TEMP%\go-mapi\` (use any small valid mail message JSON —
  the existing fixtures under `src/native-host` work, or drop any JSON
  with `version`, `timestamp`, `bodyFormat`). The queue should update
  within ~1s without reload. If you then kill the Wails app's Go side
  while the UI is still open (simulating IPC failure), the next
  queue-update should surface a visible error message in the UI rather
  than freezing silently (subscribeQueue now logs and calls onError
  instead of swallowing the rejection).
result: pass
note: |
  Part A (queue propagation on file drop) passes. Part B (kill Go side,
  verify UI error surfacing) is not reproducible with Wails — the Go
  process hosts the WebView2 UI, so killing go-mapi.exe kills the UI
  too. The unhandled-rejection branch of subscribeQueue is therefore
  only reachable via transient Wails IPC errors or fetchQueue() throws,
  neither of which are easy to synthesise in UAT. Coverage for that
  branch remains at the unit-mechanical level (`.then(...).catch(...)`
  + onError wiring visible in queue.ts + App.svelte).

### 4. Invalid_grant path shows re-auth banner (WR-02)
expected: |
  Optional / only if you can reach devtools on this build: while signed in,
  emit `window.runtime.EventsEmit('auth-changed', { authenticated: false })`
  from the console. The red "Sign-in expired — click to restore" banner
  appears at the top, SignInScreen replaces the queue, tray flips to
  error. Clicking "Sign in again" invokes SignIn directly without the
  pre-auth modal reappearing. (This was skipped during the original UAT
  because devtools wouldn't open — feel free to skip again with the same
  reason; WR-02 was covered by unit tests and the behaviour here is
  unchanged from a user-observable angle.)
result: skipped
reason: |
  Devtools still not reachable on this Wails build (same as the original
  08-HUMAN-UAT Test 4). User-observable behaviour for WR-02 is unchanged
  from Phase 08's original verification — the fix was internal lock
  ordering in MakeAuthenticatedGmailCall, covered by
  TestRefreshInvalidGrantClears and
  TestMakeAuthenticatedGmailCall_DoubleFailClassifiesInvalidGrant.

## Summary

total: 4
passed: 3
issues: 0
pending: 0
skipped: 1
blocked: 0

## Gaps

[none yet]
