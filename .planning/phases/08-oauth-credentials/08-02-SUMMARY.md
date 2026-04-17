---
phase: 08-oauth-credentials
plan: "02"
subsystem: auth
tags: [oauth, keyring, windows-credential-manager, wails-bindings, go-keyring, auth-manager, typescript]

dependency_graph:
  requires:
    - phase: 08-01
      provides: "oauthClientID/oauthClientSecret package-level vars + D-10 guard"
  provides:
    - "AuthManager struct with LoadFromKeyring/SaveToKeyring/ClearTokens (zalando/go-keyring, Windows Credential Manager)"
    - "OAuthTokens struct: JSON-serialisable access_token/refresh_token/token_type/expiry"
    - "AuthStatus struct: Wails-bound authenticated/email/name payload"
    - "App.auth *AuthManager field wired in NewApp()"
    - "GetAuthStatus/SignIn/SignOut stub bindings on *App (D-19)"
    - "Generated wailsjs/go/main/App.d.ts + App.js + models.ts with AuthStatus type"
    - "credentials_check.go / credentials_check_bindings.go split for bindings-tag compatibility"
  affects:
    - "08-03 (PKCE loopback sign-in flow — calls am.SaveToKeyring / am.ClearTokens)"
    - "08-04 (token refresh, revoke, re-auth UX — calls am.LoadFromKeyring on startup)"
    - "08-05 (end-to-end wiring — frontend reads GetAuthStatus)"
    - "10 (installer — wails build pipeline now requires the !bindings guard to be present)"

tech-stack:
  added:
    - "github.com/zalando/go-keyring v0.2.8 — Windows Credential Manager via wincred"
    - "github.com/danieljoos/wincred v1.2.3 (transitive, pulled by go-keyring)"
  patterns:
    - "Build-tag split for D-10 guard: credentials_check.go (!bindings) + credentials_check_bindings.go (bindings) — required whenever main() has fatal startup checks that must not run during wails build binding generation"
    - "saveToKeyringLocked / SaveToKeyring public-wrapper pattern: Plan 03 calls locked variant from inside mutex; tests use public wrapper"
    - "ErrNotFound-as-signed-out: keyring.ErrNotFound on Get/Delete treated as no-op (D-12) — never surfaced as error to callers"
    - "QUAL-03: no OAuthTokens struct formatted with %v/%+v/%#v in production code (grep enforced)"

key-files:
  created:
    - "src/app/auth.go"
    - "src/app/auth_test.go"
    - "src/app/credentials_check.go"
    - "src/app/credentials_check_bindings.go"
  modified:
    - "src/app/app.go"
    - "src/app/main.go"
    - "src/app/go.mod"
    - "src/app/go.sum"
    - "src/app/frontend/wailsjs/go/main/App.d.ts"
    - "src/app/frontend/wailsjs/go/main/App.js"
    - "src/app/frontend/wailsjs/go/models.ts"
    - "src/app/frontend/wailsjs/runtime/package.json"
    - "src/app/frontend/wailsjs/runtime/runtime.d.ts"
    - "src/app/frontend/wailsjs/runtime/runtime.js"

key-decisions:
  - "Used zalando/go-keyring v0.2.8 (latest v0.2.x) instead of v0.2.6 from plan — same API surface, newer patch"
  - "Build-tag split for D-10 guard: extracted inline check from main.go into credentials_check.go (!bindings) + no-op credentials_check_bindings.go to allow wails build binding generation without real credentials (Rule 3 auto-fix)"
  - "saveToKeyringLocked (unexported) + SaveToKeyring (exported public wrapper) split: Plan 03 holds the mutex while writing; tests use the wrapper"

patterns-established:
  - "Wails bindings guard pattern: any fatal startup check in main.go must be extracted to a !bindings-tagged file when using wails build"

requirements-completed: [AUTH-03, QUAL-03]

duration: 5min
completed: 2026-04-17
---

# Phase 8 Plan 02: AuthManager Scaffold + Wails Bindings Summary

**AuthManager with Windows Credential Manager round-trip (zalando/go-keyring), OAuthTokens/AuthStatus types, 6 unit tests, and Wails-generated TypeScript bindings surface for GetAuthStatus/SignIn/SignOut**

## Performance

- **Duration:** ~5 minutes
- **Started:** 2026-04-17T21:37:07Z
- **Completed:** 2026-04-17T21:42:07Z
- **Tasks:** 2 (Task 1 TDD, Task 2 bindings regen)
- **Files modified:** 14

## Accomplishments

- Created `src/app/auth.go` with `AuthManager`, `OAuthTokens`, `AuthStatus` types and full keyring lifecycle (load/save/clear) backed by Windows Credential Manager via zalando/go-keyring
- All 6 unit tests pass against the real Credential Manager (TestAuthManagerKeyringRoundTrip proves the full save→load round-trip; TestClearTokensIsIdempotent proves D-12 idempotency; TestLoadFromKeyringNoEntryIsSignedOut proves ErrNotFound-as-signed-out)
- `wails build` successfully regenerated `App.d.ts`, `App.js`, `models.ts` with `GetAuthStatus`, `SignIn`, `SignOut`, and `AuthStatus` — frontend TypeScript build green against new surface

## Task Commits

1. **Task 1: AuthManager + keyring + Wails stubs** - `27bbd59` (feat)
2. **Task 2: Regenerate Wails bindings** - `9c02ba7` (feat)

**Plan metadata:** (committed below with SUMMARY + STATE + ROADMAP)

## Files Created/Modified

- `src/app/auth.go` — AuthManager struct, OAuthTokens, AuthStatus, keyring load/save/clear, GetAuthStatus/SignIn/SignOut stubs on *App
- `src/app/auth_test.go` — 6 unit tests covering JSON round-trip, zero-value, real keyring round-trip, ErrNotFound-as-signed-out, idempotent clear, in-memory status
- `src/app/credentials_check.go` — D-10 fatal guard (build tag: !bindings)
- `src/app/credentials_check_bindings.go` — no-op stub (build tag: bindings)
- `src/app/app.go` — App struct gains `auth *AuthManager`; NewApp initialises it
- `src/app/main.go` — inline D-10 guard replaced with `checkOAuthCredentials()` call
- `src/app/go.mod` / `go.sum` — zalando/go-keyring v0.2.8 added
- `src/app/frontend/wailsjs/go/main/App.d.ts` — GetAuthStatus/SignIn/SignOut + AuthStatus
- `src/app/frontend/wailsjs/go/main/App.js` — matching JS bindings
- `src/app/frontend/wailsjs/go/models.ts` — main.AuthStatus class added
- `src/app/frontend/wailsjs/runtime/*` — runtime files regenerated (no functional change)

## Decisions Made

1. **zalando/go-keyring v0.2.8 pinned** (plan specified v0.2.6 as the stable point; v0.2.8 is the actual latest and has the same API surface — used the newer patch).
2. **Build-tag split for D-10 guard** — see Deviations below (Rule 3 auto-fix).
3. **saveToKeyringLocked / SaveToKeyring split** — Plan 03 will hold `am.refresh` while saving a freshly exchanged token; a public wrapper lets tests call SaveToKeyring without pre-locking.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] D-10 guard in main.go blocked wails build binding generation**
- **Found during:** Task 2 (Rebuild Wails bindings)
- **Issue:** The D-10 fatal guard added in Plan 01 runs inside `main()`. The Wails binding generator compiles the project with `-tags bindings` and runs the resulting binary to introspect method signatures. Because `main()` is called, `checkOAuthCredentials()` (then inline) triggered `os.Exit(1)` before Wails could emit any TypeScript — binding generation always produced exit code 1 with no output.
- **Fix:** Extracted the inline D-10 check from `main.go` into `credentials_check.go` (build tag `!bindings`) and added `credentials_check_bindings.go` (build tag `bindings`) containing a no-op `checkOAuthCredentials()`. Normal builds (`go build`, `wails dev`, release) compile `credentials_check.go` and retain the fatal guard. The wailsbindings.exe compiles `credentials_check_bindings.go` and skips the check.
- **Files modified:** `src/app/main.go`, `src/app/credentials_check.go` (new), `src/app/credentials_check_bindings.go` (new)
- **Verification:** `go build ./...` passes (normal tag); `go build -tags bindings -o /tmp/wailsbindings2.exe . && /tmp/wailsbindings2.exe` exits 0 and prints all type conversions; `wails build` succeeds end-to-end.
- **Committed in:** `9c02ba7` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 3 — blocking issue)
**Impact on plan:** Necessary for bindings generation to work at all. Strictly scoped to the D-10 guard; the guard itself remains fully active on all non-bindings build paths.

## Issues Encountered

- `wails generate module` is unavailable in v2.12.0 (exits 1 silently) — fell back to `wails build` per plan's documented fallback path.
- Both `wails build` and `wails generate module` failed with `exit status 1` and no error message until the root cause (D-10 exit blocking binding generation) was diagnosed by running the bindings binary manually.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- **08-03 (PKCE loopback sign-in):** `AuthManager.SaveToKeyring`, `saveToKeyringLocked`, `am.tokens`, `am.email`, `am.name`, `am.cancelFlow`, and `ErrInvalidGrant` are all in place. Plan 03 only needs to implement `SignIn()` and wire the loopback listener.
- **08-04 (token refresh + sign-out):** `ClearTokens()` and `LoadFromKeyring()` are ready. `SignOut()` stub is wired.
- **08-05 (end-to-end wiring):** Frontend has `GetAuthStatus()` typed and importable; `AuthStatus` class is in `models.ts`.
- No blockers.

## Known Stubs

- `App.SignIn()` — returns `errors.New("SignIn not implemented until Plan 03")`. Intentional placeholder; Plan 03 implements the full PKCE loopback flow.
- `App.SignOut()` — returns `errors.New("SignOut not implemented until Plan 04")`. Intentional placeholder; Plan 04 implements revoke + clear.

These stubs are designed: the frontend cannot trigger them accidentally because the sign-in button (Plan 05) and sign-out control (Plan 04) are not wired yet.

## Threat Surface Scan

No new network endpoints, file access patterns, or schema changes at trust boundaries introduced. The keyring read/write path was the planned trust boundary (process memory → Windows Credential Manager) and is covered by the plan's threat register (T-08-10 through T-08-14).

## Self-Check: PASSED

- `src/app/auth.go` — FOUND; contains `type AuthManager struct` (line 48), `OAuthTokens` (line 31), `AuthStatus` (line 41)
- `src/app/auth_test.go` — FOUND; contains `TestOAuthTokens` (line 13)
- `src/app/credentials_check.go` — FOUND; contains `!bindings` tag and `checkOAuthCredentials`
- `src/app/credentials_check_bindings.go` — FOUND; contains `bindings` tag and no-op stub
- `src/app/go.mod` — contains `github.com/zalando/go-keyring v0.2.8` (line 9)
- `src/app/frontend/wailsjs/go/main/App.d.ts` — contains `GetAuthStatus`, `SignIn`, `SignOut`
- `src/app/frontend/wailsjs/go/models.ts` — contains `AuthStatus`
- Commit `27bbd59` (Task 1) — FOUND
- Commit `9c02ba7` (Task 2) — FOUND
- `go test ./...` in `src/app` — PASSED (0.661s)
- `go vet ./...` — PASSED (no output)
- `npm run build` in `src/app/frontend` — PASSED (36.72 kB JS bundle)
