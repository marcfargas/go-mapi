---
phase: 08-oauth-credentials
plan: "05"
subsystem: frontend
tags: [svelte5, wails, auth-ux, oauth]
dependency_graph:
  requires: [08-04]
  provides: [auth-ui, sign-in-screen, pre-auth-modal, reauth-banner, signed-in-header]
  affects: [src/app/frontend/src/App.svelte, src/app/frontend/src/lib/auth.ts]
tech_stack:
  added: []
  patterns: [svelte5-runes, wails-eventson, localStorage-flag, derived-state]
key_files:
  created:
    - src/app/frontend/src/lib/auth.ts
    - src/app/frontend/src/lib/components/SignInScreen.svelte
    - src/app/frontend/src/lib/components/PreAuthModal.svelte
    - src/app/frontend/src/lib/components/ReAuthBanner.svelte
    - src/app/frontend/src/lib/components/SignedInHeader.svelte
  modified:
    - src/app/frontend/src/App.svelte
    - src/app/frontend/src/lib/queue.ts
decisions:
  - "Used $derived for displayName in SignedInHeader to properly react to prop changes in Svelte 5"
  - "Made queue.ts EmailWithId.message optional and aligned version/bodyFormat types to match generated wailsjs models"
  - "App.svelte uses wasAuthenticated flag (plain boolean, not reactive) to track auth transitions for banner trigger"
metrics:
  duration: "~25 minutes"
  completed: "2026-04-18"
  tasks_completed: 2
  tasks_total: 2
  files_created: 5
  files_modified: 2
---

# Phase 08 Plan 05: Frontend Auth UX Summary

Auth-aware Svelte 5 frontend: welcome/sign-in screen, one-time pre-auth modal (D-02), signed-in-as header with sign-out (D-15, D-17), red re-auth banner on invalid_grant mid-session (D-05b), all wired to Go bindings via Wails EventsOn + generated App bindings.

## Tasks Completed

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | Auth store + four components | b314de4 | auth.ts, SignInScreen.svelte, PreAuthModal.svelte, ReAuthBanner.svelte, SignedInHeader.svelte |
| 2 | App.svelte auth gating + queue.ts type fix | b189f6a | App.svelte, queue.ts, SignedInHeader.svelte (fix) |

## What Was Built

**auth.ts** — Svelte 5 module (not a store per se — uses plain async functions and EventsOn) providing:
- `fetchAuthStatus()` — calls `GetAuthStatus()` Wails binding
- `subscribeAuth(cb)` — wraps `EventsOn('auth-changed', ...)`, returns unsubscribe function
- `signIn()` / `signOut()` — thin wrappers over Wails bindings
- `hasSeenPreAuthExplainer()` / `markPreAuthExplainerSeen()` — localStorage flag (key: `go-mapi.preauth-seen`) for one-time modal D-02

**SignInScreen.svelte** — Welcome screen with "Sign in with Google" CTA and privacy copy. Shown when `auth.authenticated === false`.

**PreAuthModal.svelte** — One-time modal explaining "Google hasn't verified this app" warning with "Advanced -> Go to go-mapi (unsafe)" clickpath. Shown on first sign-in attempt; localStorage flag prevents re-show.

**ReAuthBanner.svelte** — Red banner "Sign-in expired — click to restore". Appears when auth transitions `true → false` mid-session (wasAuthenticated=true, new state authenticated=false). Never shows on cold start with no auth.

**SignedInHeader.svelte** — "Signed in as \<email\>" header with Sign out button. Visible only when `auth.authenticated === true`.

**App.svelte** — Rewired to:
1. Fetch auth + queue in parallel on mount
2. Subscribe to `auth-changed` events; track `wasAuthenticated` for banner trigger
3. Gate entire queue view on `auth.authenticated`; show SignInScreen otherwise
4. Overlay modal (rendered at bottom, `position: fixed`) when `showPreAuthModal`
5. Banner at top of window when `showReAuthBanner`
6. Re-auth click (D-06): skips pre-auth modal (localStorage flag already set)

## Verification Results

- `npm run check`: 0 errors, 1 pre-existing warning (tabindex on `<li>` in queue row — present in original App.svelte, out of scope)
- `npm run build`: passes, dist/ regenerated (41.20 kB JS bundle)
- `go build ./...` from `src/app/`: passes
- `go test ./...` from `src/app/`: passes (0.772s)
- `-race` flag not supported on windows/arm64 platform; tests pass without it

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed Svelte 5 reactive derivation in SignedInHeader**
- **Found during:** Task 1 (npm run check)
- **Issue:** `const displayName = email || name || 'your Google account'` captures initial prop value; Svelte 5 warns `state_referenced_locally`
- **Fix:** Changed to `const displayName = $derived(email || name || 'your Google account')`
- **Files modified:** `src/app/frontend/src/lib/components/SignedInHeader.svelte`
- **Commit:** b189f6a

**2. [Rule 1 - Bug] Fixed queue.ts interface type mismatches vs generated wailsjs models**
- **Found during:** Task 2 (npm run check showed pre-existing ERROR)
- **Issue:** `EmailWithId.message` typed as `MailMessage` (non-optional) but generated model has `message?: MailMessage`; `version` typed as `string` but generated as `number`; `bodyFormat` typed as `'plain' | 'html'` but generated model returns `string`
- **Fix:** Made `message` optional, `version: number`, `bodyFormat: string` in queue.ts; added optional chaining in App.svelte template (`item.message?.from?.address`, `item.message?.subject`, `item.message ? formatTimestamp(...) : ''`)
- **Files modified:** `src/app/frontend/src/lib/queue.ts`, `src/app/frontend/src/App.svelte`
- **Commit:** b189f6a

## Known Stubs

None — all auth flow wires to real Go bindings. `fetchAuthStatus()` returns real state from keyring bootstrap; `SignIn()` initiates real loopback flow; `SignOut()` revokes and clears keyring.

## Threat Flags

None — no new network endpoints or trust boundaries introduced. All XSS mitigations in place: Svelte escapes `{displayName}` and all other interpolations; no `{@html}` used.

## Self-Check: PASSED

Files exist:
- src/app/frontend/src/lib/auth.ts: FOUND
- src/app/frontend/src/lib/components/SignInScreen.svelte: FOUND
- src/app/frontend/src/lib/components/PreAuthModal.svelte: FOUND
- src/app/frontend/src/lib/components/ReAuthBanner.svelte: FOUND
- src/app/frontend/src/lib/components/SignedInHeader.svelte: FOUND
- src/app/frontend/dist/index.html: FOUND (build output)

Commits exist:
- b314de4: FOUND (Task 1 — auth store + components)
- b189f6a: FOUND (Task 2 — App.svelte integration + queue.ts fix)
