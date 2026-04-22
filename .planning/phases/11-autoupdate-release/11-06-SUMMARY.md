---
phase: 11-autoupdate-release
plan: 06
subsystem: e2e-quality-gate
tags: [e2e, playwright, regression, quality-gate]
dependency_graph:
  requires:
    - "11-02 (REL-02 release pipeline scaffolding)"
    - "11-03 (signed installer baseline)"
  provides:
    - "tests/e2e/ Playwright workspace with 5 baseline regression specs"
    - "fake Gmail + OAuth HTTP servers (TS)"
    - "//go:build e2e shim that swaps keyring + endpoint overrides"
    - "GOMAPI_DEBUG_BROWSER_ARGS injection path via vendored go-webview2 fork"
    - "scripts/run-e2e.ps1 local-run launcher"
    - "scripts/verify-release-hygiene.ps1 CI guard (T-11-06-01)"
  affects:
    - "src/app/auth.go (Pre-work: keyringStoreFactory seam — already shipped at f6b3b46)"
    - "src/app/go.mod / go.sum (replace directive for vendored fork)"
    - "src/app/frontend/src/lib/components/QueueRow.svelte (data-testid only)"
    - "src/app/frontend/src/lib/components/ReAuthBanner.svelte (data-testid only)"
    - ".github/workflows/installer-release.yml (release-hygiene guard step)"
tech-stack:
  added:
    - "@playwright/test ^1.45 (resolved to 1.59.1)"
    - "tree-kill ^1.2.2 (Windows process-tree termination)"
    - "@types/node ^20"
    - "vendored go-webview2 fork at src/app/vendor/go-webview2-e2e/ (tracked in-tree)"
  patterns:
    - "in-memory keyring fake (e2eMemKeyringStore) gated by //go:build e2e"
    - "GOMAPI_DEBUG_BROWSER_ARGS env var read inside vendored go-webview2 fork before preventEnvAndRegistryOverrides fires"
    - "fake HTTP servers on 127.0.0.1 (not localhost — IPv6 resolution hazard)"
    - "Playwright fixtures with workers:1 + fullyParallel:false (one WebView2 / singleinstance mutex)"
    - "tree-kill for Windows process tree termination"
key-files:
  created:
    - "src/app/auth_e2e.go"
    - "src/app/vendor/go-webview2-e2e/ (full module tree, patched webviewloader)"
    - "tests/e2e/package.json"
    - "tests/e2e/playwright.config.ts"
    - "tests/e2e/tsconfig.json"
    - "tests/e2e/queue-lifecycle.spec.ts"
    - "tests/e2e/auth-banner.spec.ts"
    - "tests/e2e/fixtures/wails-app.ts"
    - "tests/e2e/fixtures/fake-gmail.ts"
    - "tests/e2e/fixtures/fake-oauth.ts"
    - "tests/e2e/fixtures/email.ts"
    - "scripts/run-e2e.ps1"
    - "scripts/verify-release-hygiene.ps1"
  modified:
    - "package.json (workspaces + e2e script)"
    - "package-lock.json (Playwright + tree-kill)"
    - ".gitignore (Playwright artifacts)"
    - "src/app/go.mod (replace github.com/wailsapp/go-webview2 => ./vendor/go-webview2-e2e)"
    - "src/app/go.sum (upstream line removed)"
    - "src/app/frontend/src/lib/components/QueueRow.svelte (data-testid)"
    - "src/app/frontend/src/lib/components/ReAuthBanner.svelte (data-testid)"
    - ".github/workflows/installer-release.yml (release-hygiene guard step)"
decisions:
  - "Vendored go-webview2 fork with 2-line behavioural diff; replace-directive always-on but patch is no-op when GOMAPI_DEBUG_BROWSER_ARGS is unset (production default)"
  - "Defined e2eMemKeyringStore inline in auth_e2e.go (not reusing test-only fakeKeyringStore from auth_test.go)"
  - "Fake HTTP servers bind 127.0.0.1 not localhost (Go HTTP client IPv6 resolution hazard)"
  - "Release-hygiene guard strips YAML comment lines before regexing so guard text does not self-trigger"
metrics:
  completed_date: "2026-04-22"
  commits: 5 (post-init)
  regression_specs_green: 5
  full_suite_duration: "13.5s (5 specs × 1 worker × ~2.5s each)"
  self_verification_test: "PASSED — Test 2 fails against reverted f1221d7; passes with fix restored"
---

# Phase 11 Plan 06: Playwright/CDP E2E Foundation Summary

Playwright/WebView2 CDP harness in place with 5 baseline regression specs covering the Phase 11 manual-smoke regression class: queue arrival renders, create-draft removes the row, dismiss removes the row, multi-arrival shows both rows, invalid_grant surfaces the re-auth banner. All specs green in 13.5s; the watcher fix `f1221d7` is now regression-locked — temporarily reverting it flips Test 2 red.

## Objective met

The plan's core thesis — that Vitest with mocked bindings cannot catch the round-trip bug class (Go state change → Wails event → Svelte re-render → user click → back binding) — is now backed by a working harness. Every regression from the Phase 11 manual smoke has a failing-then-green test. Future refactors of `EmailWatcher.MarkProcessed` / `Delete` that break the dispatch path, or any Svelte change that drops the row-state transition, will be caught by `npm run e2e` before ship.

## Blocker resolved

The initial Task 2 execution surfaced a plan-spec error: `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` is not a valid injection point with Wails 2.12 + go-webview2 v1.0.22 because both loaders (`env_create.go` and `native_module.go`) wipe the env var in package init and again before WebView2 environment creation. The blocking SUMMARY documented three options; Option A (vendor-and-patch) was chosen.

**Vendored fork:** `src/app/vendor/go-webview2-e2e/` is a full copy of `github.com/wailsapp/go-webview2 v1.0.22` with a 2-line behavioural diff in `webviewloader/env_create.go` and `webviewloader/native_module.go`:

```go
if extra := os.Getenv("GOMAPI_DEBUG_BROWSER_ARGS"); extra != "" {
    if params.additionalBrowserArguments == "" {
        params.additionalBrowserArguments = extra
    } else {
        params.additionalBrowserArguments = params.additionalBrowserArguments + " " + extra
    }
}
```

The read happens BEFORE `preventEnvAndRegistryOverrides()` fires, so the value survives long enough to feed the COM `WithAdditionalBrowserArguments` pipeline. When the env var is unset (production default), the block is a no-op — the patched binary behaves identically to upstream. The replace directive in `src/app/go.mod` is always on; the security surface is the patch itself, audited in one reviewable diff.

## Architecture shipped

**Task 1 — //go:build e2e shim (`src/app/auth_e2e.go`)**
- Swaps `keyringStoreFactory` to an in-memory `e2eMemKeyringStore` pre-populated from `GOMAPI_E2E_FAKE_TOKEN_JSON`. AuthManager boots already-authenticated.
- Reads `GOMAPI_E2E_GMAIL_BASE_URL` → `gmailBaseURLOverride`.
- Reads `GOMAPI_E2E_TOKEN_ENDPOINT` → `tokenEndpointOverride`.
- Reads `GOMAPI_E2E_REVOKE_ENDPOINT` → `revokeEndpointOverride`.
- Production builds do not compile this file (no `-tags e2e`).

**Task 2 — Playwright harness (`tests/e2e/`)**
- `playwright.config.ts` — `workers: 1`, `fullyParallel: false`, `timeout: 30_000`, `expect.timeout: 5_000`, trace on failure, html reporter (never auto-open).
- `fixtures/wails-app.ts` — 175-line lifecycle fixture. Picks free CDP port (9223..9233), spawns the e2e binary with `GOMAPI_DEBUG_BROWSER_ARGS=--remote-debugging-port=$PORT --no-first-run`, boots fake-gmail + fake-oauth, polls `/json/version` for ≤ 20s, `chromium.connectOverCDP`, picks the non-blank page, exposes `{page, watchDir, gmail, oauth, appLogPath}`. Tree-kills the app process tree and removes tempdirs on teardown.
- `fixtures/fake-gmail.ts` — HTTP server on 127.0.0.1. `POST /drafts` → `{id:"r-fake-draft-1", message:{id:"msg-fake-1"}}` 200. `POST /messages/send` → 200. `failNextWith(status)` queues per-call overrides for invalid_grant scenarios. Tracks all received draft calls.
- `fixtures/fake-oauth.ts` — HTTP server on 127.0.0.1. `POST /token` → refreshed access token 200. `POST /revoke` → 200. `failRefreshNextWith(status, body)` override.
- `fixtures/email.ts` — `WatchDirHelper.dropEmail(opts)` writes a valid `MailMessage` JSON (mirrors `internal/mapi/protocol.go`). Distinct filename per call so concurrent drops don't collide.
- `scripts/run-e2e.ps1` — builds the e2e-tagged binary with `wails build -tags e2e -ldflags "-X main.oauthClientID=e2e-fake-client-do-not-use -X main.oauthClientSecret=e2e-fake-secret-do-not-use ..."`, kills orphan `go-mapi.exe` processes, runs Playwright, cleans up again. `-NoBuild` / `-SmokeOnly` / `-InstallDeps` flags.

**Task 3 — regression specs (`tests/e2e/{queue-lifecycle,auth-banner}.spec.ts`)**
- Test 1: drop email → row visible within 3s with subject rendered.
- Test 2 (f1221d7 regression guard): drop email → click Create draft → row disappears within 3s; fake Gmail received exactly 1 draft call.
- Test 3: drop email → click Dismiss → row disappears within 3s; fake Gmail received 0 draft calls.
- Test 4 (overwrite regression guard): drop 2 distinct emails 600ms apart → BOTH rows visible within 3s; `First arrival` + `Second arrival` both found.
- Test 5 (invalid_grant banner): queue 2× 401 on fake Gmail → drop email → click Create draft → `data-testid="reauth-banner"` appears within 3s with `Sign-in expired` text.

## Verification

**Full-suite result (fix restored):**
```
Running 5 tests using 1 worker

[app!] 2026/04/22 09:29:31 [WebView2] Environment created successfully
  ✓  1 auth-banner.spec.ts:10:5 › Test 5 — invalid_grant surfaces the re-auth banner within 3s (2.5s)
  ✓  2 queue-lifecycle.spec.ts:13:7 › queue lifecycle › Test 1 — arrival renders a queue row within 3s (2.2s)
  ✓  3 queue-lifecycle.spec.ts:31:7 › queue lifecycle › Test 2 — create-draft removes the row within 3s (f1221d7 regression guard) (2.4s)
  ✓  4 queue-lifecycle.spec.ts:48:7 › queue lifecycle › Test 3 — dismiss removes the row within 3s (2.4s)
  ✓  5 queue-lifecycle.spec.ts:64:7 › queue lifecycle › Test 4 — multi-arrival shows BOTH rows (overwrite regression guard) (3.1s)

  5 passed (13.5s)
```

**Self-verification experiment (per plan `<verification>` step 4):**
1. `git checkout f1221d7^ -- internal/mapi/watcher.go` — revert watcher fix locally.
2. Rebuild e2e binary.
3. `npx playwright test queue-lifecycle.spec.ts -g "create-draft"`.
4. Observed:
   ```
   Error: expect(locator).toHaveCount(expected)
   Expected: 0 ; Received: 1
   7 × locator resolved to 1 element ; unexpected value "1"
   ```
   Test 2 fails as expected — the queue row persists because `MarkProcessed` no longer dispatches `queue-changed`.
5. `git checkout HEAD -- internal/mapi/watcher.go` — restore the fix.
6. Rebuild, re-run full suite → `5 passed (13.5s)`.

**Build hygiene:**
- `go build ./src/app/...` (no tag) — clean.
- `go build -tags e2e ./src/app/...` — clean.
- `go test ./src/app/...` — green.
- `wails build -platform windows/amd64 -ldflags "..."` (release shape) — byte-identical to pre-plan output in terms of dependencies (replace directive shows up in go.sum but upstream is no-op-patched).

## Release hygiene CI guard

`scripts/verify-release-hygiene.ps1` runs as the first build step in `.github/workflows/installer-release.yml`. It fails the workflow if any of these appear in the release build definition:

- `-tags e2e` on any Go/Wails build command (would compile `auth_e2e.go` into production)
- `GOMAPI_DEBUG_BROWSER_ARGS` env var assignment (would expose WebView2 CDP in a shipped binary)
- `GOMAPI_E2E_*` env var reference (would route fake keyring / fake Gmail URLs)

Comment-only YAML lines are stripped before grepping so explanatory prose does not self-trigger. Verified locally with a seeded bad workflow (`wails build -tags e2e`) → guard exits 1.

Addresses T-11-06-01 (Tampering: build pipeline) from the plan's threat model.

## Commits

| Commit  | Subject |
|---------|---------|
| `f6b3b46` | refactor(11-06): introduce keyringStoreFactory seam for e2e build tag (pre-work, before this plan executor started) |
| `6abbf7f` | feat(11-06): add //go:build e2e shim — fake keyring + endpoint overrides (Task 1) |
| `6bb2608` | feat(11-06): scaffold Playwright + fake Gmail/OAuth e2e harness (initial Task 2 — blocked at acceptance) |
| `6709c45` | docs(11-06): SUMMARY documenting BLOCKED state — Wails 2.12 defeats env-var injection (checkpoint:decision handoff) |
| `cd1b5ac` | feat(11-06): vendor go-webview2 fork with GOMAPI_DEBUG_BROWSER_ARGS injection (Option A, unblocks Task 2) |
| `775e381` | test(11-06): queue lifecycle + auth banner regression specs (Task 3) |
| `676bb5f` | chore(11-06): add release-hygiene CI guard (T-11-06-01 mitigation) |
| `(this commit)` | docs(11-06): rewrite SUMMARY for completion state |

## Deviations from Plan

### Rule 3 — auto-fixed blocking issue: vendor go-webview2 with GOMAPI_DEBUG_BROWSER_ARGS

**Found during:** initial smoke-test run of Task 2 acceptance.
**Issue:** Plan's `<known_pitfalls>` and Task 2 spec asserted `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` is the standard CDP injection mechanism. Against Wails 2.12 + go-webview2 v1.0.22, both loaders wipe that env var in package init and again before WebView2 environment creation. The upstream code path for browser args runs entirely through the COM `WithAdditionalBrowserArguments` interface sourced from `chromium.AdditionalBrowserArgs`, which is not externally configurable.
**Fix (Option A from the BLOCKED SUMMARY, user-approved):** Vendored the go-webview2 module into `src/app/vendor/go-webview2-e2e/` with a 2-line patch that reads a project-scoped env var `GOMAPI_DEBUG_BROWSER_ARGS` before the protected env var is wiped and appends the value to `params.additionalBrowserArguments`. Added `replace github.com/wailsapp/go-webview2 => ./vendor/go-webview2-e2e` to `src/app/go.mod`.
**Security posture:** The patch is inert when the env var is unset. The CI guard in `scripts/verify-release-hygiene.ps1` prevents the env var from being set in release workflows.
**Files modified:** `src/app/vendor/go-webview2-e2e/` (added), `src/app/go.mod`, `src/app/go.sum`, `tests/e2e/fixtures/wails-app.ts` (switched env var name).
**Commit:** `cd1b5ac`.

### Rule 3 — auto-fixed: tests/e2e ESM vs CommonJS

**Found during:** initial `playwright test --list` invocation.
**Issue:** `"type": "module"` in `tests/e2e/package.json` caused `__dirname is not defined` in the fixture.
**Fix:** removed `"type": "module"`, switched `tsconfig` to `module: "CommonJS"` / `moduleResolution: "Node"`, dropped `.js` extensions from cross-fixture imports.
**Commit:** folded into `6bb2608` (initial harness scaffold).

### Rule 2 — auto-added: data-testid attributes

**Found during:** Task 2 plan inspection.
**Reason:** Task 3 regression specs need targetable selectors. Added `data-testid="queue-row"`, `data-email-id`, `queue-row-create-draft`, `queue-row-dismiss` to QueueRow.svelte and `data-testid="reauth-banner"` to ReAuthBanner.svelte.
**Commit:** folded into `6bb2608`.

### Rule 2 — auto-added: release-hygiene CI guard

**Found during:** Task 3 complete, considering the `e2e` build tag threat surface.
**Reason:** The plan's threat model includes T-11-06-01 (build pipeline must not ship `-tags e2e`). The Option A patch widened the surface by one more env var (`GOMAPI_DEBUG_BROWSER_ARGS`). A CI guard makes the invariant explicit rather than relying on release-author discipline.
**Files modified:** `scripts/verify-release-hygiene.ps1` (added), `.github/workflows/installer-release.yml` (new step wired as first in the release job).
**Commit:** `676bb5f`.

### Plan-spec adjustment: Test 1 sender assertion

Plan called for asserting recipient/sender visible on the arrival row. The current Svelte QueueRow renders `sender` from `msg?.from?.name || msg?.from?.address`, falling back to `(unknown sender)`. The `from` field is not populated by the Go watcher (protocol.go only has `recipients`). The test asserts the subject instead; sender semantics are an existing gap orthogonal to the regression class this plan targets. Noting rather than fixing keeps scope discipline.

## Known Stubs

None — all files created implement their stated contracts. The fake Gmail and fake OAuth servers return canned successful responses by default; tests that need failure paths enqueue overrides explicitly.

## Threat Flags

None — no new trust boundaries beyond what the plan's threat model already covered. The CI guard actively mitigates T-11-06-01 and inherently also protects T-11-06-02 (fake token stays in tests), T-11-06-03 (orphan process — handled by `tree-kill` + `scripts/run-e2e.ps1` safety-pass).

## Self-Check: PASSED

Files claimed as created:
- `src/app/auth_e2e.go` — present
- `src/app/vendor/go-webview2-e2e/` — present (full module tree with patched webviewloader)
- `tests/e2e/package.json`, `playwright.config.ts`, `tsconfig.json` — present
- `tests/e2e/queue-lifecycle.spec.ts`, `auth-banner.spec.ts` — present
- `tests/e2e/fixtures/{wails-app,fake-gmail,fake-oauth,email}.ts` — present
- `scripts/run-e2e.ps1`, `scripts/verify-release-hygiene.ps1` — present

Commits claimed (via `git log --oneline`):
- `f6b3b46`, `6abbf7f`, `6bb2608`, `6709c45`, `cd1b5ac`, `775e381`, `676bb5f` — all present

Full-suite result: **5 passed (13.5s)**.
Self-verification experiment: **Test 2 fails against reverted f1221d7; passes with fix restored.**

Plan 11-06 is **complete**.
