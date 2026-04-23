---
created: 2026-04-23T13:45:00.000Z
title: Sign-In button stuck after failed OAuth attempt
area: auth
files:
  - src/app/auth.go
  - src/app/frontend/src/lib/auth.ts
  - src/app/frontend/src/lib/components/SignInScreen.svelte
---

## Problem

Reported during Phase 11 clean-machine smoke on 2026-04-23: if the user clicks "Sign in" and the OAuth consent flow fails or is cancelled mid-flight, the Sign-In button does not become clickable again. The only way to recover is to quit and relaunch the app.

Likely cause (to be confirmed by debugging): `AuthManager.SignIn()` takes a lock or sets an in-flight flag at the start of the loopback-listener / browser-open path, and the flag is never cleared when the user closes the consent window, denies consent, or the loopback listener times out. The UI observes this as "sign-in pending" and refuses to re-dispatch the binding.

## Repro (tentative)

1. Launch a fresh go-mapi (signed-out state).
2. Click "Sign in" on `SignInScreen.svelte`.
3. When the browser opens the Google consent page, close the tab without granting consent (or deny).
4. Return to the app window.
5. Click "Sign in" again → **button does not fire / stays disabled**.

## Suspected code paths to inspect

- `src/app/auth.go` — `AuthManager.SignIn()` + any `inFlight atomic.Bool` / mutex pattern that isn't cleared on the error return paths.
- `src/app/frontend/src/lib/auth.ts` — the wrapper that calls the wailsjs `App.SignIn` binding; does it set a local "signing in" state that is only cleared on the success event?
- `src/app/frontend/src/lib/components/SignInScreen.svelte` — does the button have a `disabled` bound to a reactive state that never gets reset on reject?

## Fix approach (preliminary — debug first)

1. Ensure every error path in `AuthManager.SignIn()` clears the in-flight flag with `defer`.
2. Ensure the frontend Svelte component has an `onError` branch that resets the local "in progress" state, and/or the Go side emits an `auth-changed` event with the error state on every failure (not just invalid_grant).
3. Add a timeout on the loopback listener + "cancel sign-in" escape hatch in the UI so a stuck flow is user-recoverable.

## Priority

Medium. Does not block the v3.0 GA cut (the happy path works), but is a UX regression that will surface on any slow-consent / denied-consent / popup-blocker scenario. Worth a 15-01 or 11.x decimal phase depending on when it's addressed.

## Verification

- Regression test in `src/app/frontend/src/lib/components/SignInScreen.test.ts` (new): simulate click → reject promise → click again → assert second click dispatches.
- Go-side: add a unit test in `src/app/auth_test.go` that exercises `SignIn()` with an injected loopback-listener that returns an error, and asserts a subsequent `SignIn()` call is not blocked.
