---
phase: 11-autoupdate-release
plan: 06
subsystem: e2e-quality-gate
status: blocked-architectural
tags: [e2e, playwright, regression, quality-gate, blocked]
dependency_graph:
  requires:
    - "11-02 (REL-02 release pipeline scaffolding)"
    - "11-03 (signed installer baseline)"
  provides:
    - "tests/e2e/ Playwright workspace skeleton"
    - "fake Gmail + OAuth HTTP servers (TS)"
    - "//go:build e2e shim that swaps keyring + endpoint overrides"
    - "data-testid attributes on QueueRow + ReAuthBanner"
  affects:
    - "src/app/auth.go (Pre-work: keyringStoreFactory seam — already shipped at f6b3b46)"
    - "src/app/frontend/src/lib/components/QueueRow.svelte (data-testid only)"
    - "src/app/frontend/src/lib/components/ReAuthBanner.svelte (data-testid only)"
tech-stack:
  added:
    - "@playwright/test ^1.45 (resolved to 1.59.1)"
    - "tree-kill ^1.2.2 (Windows process-tree termination)"
    - "@types/node ^20"
  patterns:
    - "in-memory keyring fake (e2eMemKeyringStore) gated by //go:build e2e"
    - "fake HTTP servers on 127.0.0.1 (not localhost — IPv6 resolution hazard)"
    - "Playwright fixtures with workers:1 + fullyParallel:false (one WebView2 / mutex)"
key-files:
  created:
    - "src/app/auth_e2e.go"
    - "tests/e2e/package.json"
    - "tests/e2e/playwright.config.ts"
    - "tests/e2e/tsconfig.json"
    - "tests/e2e/smoke.spec.ts"
    - "tests/e2e/fixtures/wails-app.ts"
    - "tests/e2e/fixtures/fake-gmail.ts"
    - "tests/e2e/fixtures/fake-oauth.ts"
    - "tests/e2e/fixtures/email.ts"
    - "scripts/run-e2e.ps1"
  modified:
    - "package.json (workspaces + e2e script)"
    - "package-lock.json (Playwright + tree-kill)"
    - ".gitignore (Playwright artifacts)"
    - "src/app/frontend/src/lib/components/QueueRow.svelte (data-testid)"
    - "src/app/frontend/src/lib/components/ReAuthBanner.svelte (data-testid)"
decisions:
  - "Use 127.0.0.1 not localhost for fake servers (Go HTTP IPv6 resolution hazard)"
  - "ldflags-injected fake OAuth creds for e2e binary (e2e-fake-client-do-not-use)"
  - "in-memory keyring fake defined inside auth_e2e.go (cannot reuse fakeKeyringStore from auth_test.go — that's _test-only)"
  - "tree-kill for Windows process tree termination (child_process.kill cannot kill descendants on Windows)"
metrics:
  completed_date: "2026-04-22"
  commits: 2
---

# Phase 11 Plan 06: Playwright/CDP E2E Foundation Summary

**Status: BLOCKED on Wails 2.12 architectural constraint. Partial scaffolding committed; user decision required to proceed.**

E2E foundation scaffolded — //go:build e2e shim, fake Gmail + fake OAuth HTTP servers, Playwright fixture, scripts/run-e2e.ps1, data-testid hooks on QueueRow + ReAuthBanner. Smoke spec passes test enumeration but the harness cannot reach the Wails app via CDP because Wails 2.12 + go-webview2 v1.0.22 explicitly defeat the `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` env-var injection mechanism the plan relies on.

## What works

- **Task 1: //go:build e2e shim** — green.
  - `src/app/auth_e2e.go` (108 lines) replaces `keyringStoreFactory` with an in-memory `e2eMemKeyringStore` in `init()`, pre-populating from `GOMAPI_E2E_FAKE_TOKEN_JSON`. Sets `gmailBaseURLOverride`, `tokenEndpointOverride`, `revokeEndpointOverride` from `GOMAPI_E2E_*` env vars.
  - `go build -tags e2e ./src/app/...` compiles clean.
  - `go build ./src/app/...` (no tag) compiles clean.
  - `go test ./src/app/...` passes (production behaviour unchanged — file not compiled in).
  - Commit: `6abbf7f`.

- **Task 2: Playwright harness scaffolding** — partial.
  - `tests/e2e/` workspace declared in root `package.json`; `npm install` resolves `@playwright/test@1.59.1` + `tree-kill@1.2.2`.
  - `playwright.config.ts` configures `workers: 1`, `fullyParallel: false`, `timeout: 30_000`, retain-on-failure traces.
  - `fixtures/wails-app.ts` (175 lines) implements full lifecycle: spawns the e2e binary, picks a free CDP port (9223..9233), boots fake-gmail + fake-oauth, polls `/json/version` for ≤ 20s, calls `chromium.connectOverCDP`, exposes `{page, watchDir, gmail, oauth}` to tests, tree-kills on teardown.
  - `fixtures/fake-gmail.ts` returns 200 stub responses for `/upload/gmail/v1/users/me/drafts` + `/messages/send`, with `failNextWith(status)` queue-overrides.
  - `fixtures/fake-oauth.ts` mirrors Google `/token` + `/revoke` endpoints, defaults to 200, with `failRefreshNextWith(status, body)` for invalid_grant scenarios.
  - `fixtures/email.ts` `WatchDirHelper.dropEmail(opts)` writes a valid `MailMessage` JSON into the watched temp dir.
  - `scripts/run-e2e.ps1` builds the e2e binary with `wails build -platform windows/amd64 -tags e2e -ldflags "-X main.oauthClientID=e2e-fake-client-do-not-use -X main.oauthClientSecret=e2e-fake-secret-do-not-use ..."`, then runs Playwright. `-NoBuild` and `-SmokeOnly` flags supported.
  - `npm exec --workspace=@marcfargas/go-mapi-e2e -- playwright install chromium` installed the headless shell.
  - Throwaway `smoke.spec.ts` enumerates correctly under `npx playwright test --list`.
  - Wails build of the e2e binary completes cleanly: `Built 'C:\dev\go-mapi\src\app\build\bin\go-mapi.exe' in 17.157s`.
  - Commit: `(this commit's parent)`.

## What is blocked

**Smoke test fails: CDP never responds on the chosen port.** The harness's `waitForCdp` polls `http://127.0.0.1:9223/json/version` for 20s, sees no response, throws.

Manual reproduction (run the e2e binary with the exact env vars the harness sets):

```bash
WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS='--remote-debugging-port=9223 --no-first-run' \
GOMAPI_E2E_FAKE_TOKEN_JSON='{"access_token":"e2e","refresh_token":"e2e","token_type":"Bearer","expiry":"2027-01-01T00:00:00Z"}' \
GOMAPI_WATCH_DIR=/tmp/x GOMAPI_APPDATA_DIR=/tmp/y \
src/app/build/bin/go-mapi.exe &

sleep 6
curl --max-time 3 http://127.0.0.1:9223/json/version  # → no response, no listener
netstat -an | grep 9223                                # → no entry
kill -0 $!                                             # → process is alive
```

The app boots, WebView2 initializes (`[WebView2] Environment created successfully` is logged), but no CDP listener is opened.

## Root cause

Wails 2.12 ships `github.com/wailsapp/go-webview2 v1.0.22`. Both code paths (`webviewloader/env_create.go` for the default Go loader, `webviewloader/native_module.go` for `-tags native_webview2loader`) call `preventEnvAndRegistryOverrides()`:

- `env_create.go` line 18 — at package `init()` time:
  ```go
  os.Setenv("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", "")
  ```
- `env_create.go` line 109 — immediately before `CreateWebViewEnvironmentWithOptionsInternal` is called.
- `native_module.go` line 128 — sets `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` to whatever Wails computed (empty by default).

So our env value is wiped twice: once at package init, once at WebView2 environment creation. Setting the env var post-init does not survive either.

The actual mechanism Wails uses to inject browser args is `chromium.AdditionalBrowserArgs []string` in `wailsapp/wails/v2@v2.12.0/internal/frontend/desktop/windows/frontend.go` line 466-489 — populated only from Wails public options (`WebviewGpuIsDisabled`, `EnableFraudulentWebsiteDetection`). There is no public Wails 2.12 API to add arbitrary browser args.

Confirmed against go-webview2 source v1.0.22:
- `pkg/edge/chromium.go:184` — `browserArgs := strings.Join(e.AdditionalBrowserArgs, " ")`
- `pkg/edge/create_env_go.go:17` — passes via COM `WithAdditionalBrowserArguments(args)`
- env var is purely defensive; never read as a positive input source

## Decision required

The plan's `<known_pitfalls>` claims `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` is the standard injection mechanism. That assumption does not hold against Wails 2.12 + go-webview2 v1.0.22. Three viable paths:

| Option | Description | Cost | Risk |
|--------|-------------|------|------|
| **A. Vendor-and-patch go-webview2** | Add a `replace` directive in `src/app/go.mod` pointing at a local fork of go-webview2 with a one-line patch reading a non-protected env var (e.g. `GOMAPI_DEBUG_BROWSER_ARGS`) and appending it to `additionalBrowserArguments` inside the `WithAdditionalBrowserArguments` chain. Replace is process-wide so the patch must be no-op when the env var is unset (which it is in production). | ~30 min — copy `webviewloader/env_create_options.go`, change one method, vendor 4-5 files | Replace directives are visible only at build time and ship to production. The patch must be inert by default; auditing the diff is a one-line review. CI must verify the patch is no-op without the env var. |
| **B. Pure-Wails-API path: drop `wails.Run`, use `pkg/edge.Chromium` directly under //go:build e2e** | Write an alternative `main_e2e.go` that bypasses Wails's frontend entirely, using `wails/v2/internal/frontend/desktop/windows.NewFrontend` with a hand-rolled chromium that has `AdditionalBrowserArgs` set. | ~2-4 hours — requires understanding Wails internals at depth | High — duplicates Wails wiring (binding generation, event emission); the e2e binary diverges from production wiring, defeating the whole point of "real Wails app" |
| **C. Replace E2E foundation: drop CDP, drive the app via the wailsjs IPC layer instead** | Skip browser-level automation. Spawn the binary, talk to it through a test-only RPC (gRPC or HTTP) added under //go:build e2e to App.struct, drive via wailsjs bindings and assertions on emitted events. Lose UI render verification. | ~1 day — large rewrite of the harness | Medium — covers the "Go-side mutation → Wails event" half of the regression class but NOT the "Svelte re-render → user click" half, which is exactly where the Phase 11 smoke regressions lived. **This option does not satisfy the plan's stated objective.** |

**Recommendation: Option A.** It is the smallest patch, keeps the plan's architecture intact, and the maintenance cost is one tracked dependency to upgrade alongside Wails. The patch can ship behind a default-off env var with explicit security audit notes in `auth_e2e.go`'s comments.

If the user accepts Option A, the next executor agent should:
1. Vendor `webviewloader/env_create.go` + `env_create_options.go` + `native_module.go` (~5 files) into `vendor/go-webview2-e2e/` or a sibling module.
2. Apply the one-line patch reading `GOMAPI_DEBUG_BROWSER_ARGS` env var and appending to `additionalBrowserArguments`.
3. Add `replace github.com/wailsapp/go-webview2 => ./path/to/fork` in `src/app/go.mod`.
4. Update `tests/e2e/fixtures/wails-app.ts` to set `GOMAPI_DEBUG_BROWSER_ARGS=--remote-debugging-port=$PORT --no-first-run` instead of `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`.
5. Verify smoke spec passes; proceed to Task 3 regression specs.
6. Add a security audit note: production binaries inherit the patch but the env var is unset by the installer; `installer-release.yml` should grep the binary for any reference to `GOMAPI_DEBUG_BROWSER_ARGS` and ensure it is not present in normal user shells.

## Files in this plan

**Created:**
- `src/app/auth_e2e.go` (108 lines) — //go:build e2e shim
- `tests/e2e/package.json`, `playwright.config.ts`, `tsconfig.json`, `smoke.spec.ts`
- `tests/e2e/fixtures/wails-app.ts`, `fake-gmail.ts`, `fake-oauth.ts`, `email.ts`
- `scripts/run-e2e.ps1`

**Modified:**
- `package.json` — added tests/e2e workspace + `e2e` script
- `package-lock.json` — Playwright + tree-kill resolved
- `.gitignore` — Playwright artifact paths
- `src/app/frontend/src/lib/components/QueueRow.svelte` — data-testid attributes
- `src/app/frontend/src/lib/components/ReAuthBanner.svelte` — data-testid attribute

## Commits

- `6abbf7f` — feat(11-06): add //go:build e2e shim — fake keyring + endpoint overrides
- `(parent of this SUMMARY commit)` — feat(11-06): scaffold Playwright + fake Gmail/OAuth e2e harness (BLOCKED)

## Deviations from Plan

### Rule 4 — Architectural Decision Required (BLOCKED)

**Plan assumption invalid:** the plan's `<known_pitfalls>` and Task 2 spec assert that setting `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=$PORT --no-first-run` in the spawn env will expose CDP from WebView2. This does not hold against Wails 2.12 + go-webview2 v1.0.22 because both loaders explicitly wipe that env var in package init AND right before WebView2 environment creation. See "Root cause" section above for code references.

**Requested decision:** Choose Option A / B / C from the Decision Required section. Default recommendation is Option A.

### Rule 3 — Auto-fixed: removed `"type": "module"` from tests/e2e/package.json

**Found during:** initial `playwright test --list` invocation
**Issue:** with `"type": "module"`, Playwright treated TS files as ESM and `__dirname` was undefined.
**Fix:** removed `"type": "module"`, switched tsconfig to `"module": "CommonJS"` / `"moduleResolution": "Node"`, dropped `.js` extensions from cross-fixture imports.
**Files modified:** `tests/e2e/package.json`, `tests/e2e/tsconfig.json`, `tests/e2e/fixtures/wails-app.ts`, `tests/e2e/smoke.spec.ts`
**Commit:** included in the harness scaffold commit (parent of this SUMMARY)

### Rule 2 — Auto-added: data-testid attributes on QueueRow buttons

**Found during:** Task 2 plan inspection
**Reason:** Task 3 needs targetable selectors for Create-draft and Dismiss buttons; the plan said "add minimal `data-testid='queue-row-{id}'`" but selectors for buttons are equally needed and trivial to add.
**Files modified:** `src/app/frontend/src/lib/components/QueueRow.svelte`, `ReAuthBanner.svelte`

## Tasks not started

- **Task 3: Queue lifecycle + auth-banner regression tests.** Cannot proceed until the CDP block in Task 2 is resolved.

## Self-Verification Step Status

The plan's `<verification>` step 4 (revert `f1221d7` locally to confirm Test 2 catches the bug, then revert the revert) was NOT performed because Task 3 specs were never written.

## Self-Check: PARTIAL

Files claimed as created: all present.
- `src/app/auth_e2e.go` — present
- `tests/e2e/package.json` — present
- `tests/e2e/playwright.config.ts` — present
- `tests/e2e/tsconfig.json` — present
- `tests/e2e/smoke.spec.ts` — present
- `tests/e2e/fixtures/wails-app.ts` — present
- `tests/e2e/fixtures/fake-gmail.ts` — present
- `tests/e2e/fixtures/fake-oauth.ts` — present
- `tests/e2e/fixtures/email.ts` — present
- `scripts/run-e2e.ps1` — present

Commits claimed as made: all present.
- `6abbf7f` — present in `git log`
- harness scaffold commit — parent of this SUMMARY commit

Plan is NOT complete. Returning checkpoint:decision.
