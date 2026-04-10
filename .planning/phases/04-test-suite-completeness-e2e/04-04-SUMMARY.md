---
phase: 04-test-suite-completeness-e2e
plan: 04
type: execute
wave: 4
status: completed
completed: 2026-04-10
requirements: [E2E-01, E2E-02, E2E-03, E2E-04, E2E-05]
---

# Wave 4 Summary — End-to-End Tests

## What shipped

- `tests/e2e/playwright.config.ts` — updated with
  `retries: process.env.CI ? 2 : 0`, `timeout: 90_000`, and trace
  retention on failure in CI. Preserved `headless: false` and
  `workers: 1`.
- `tests/e2e/mock-gmail/main.go` + `go.mod` + `README.md` — stdlib Go
  mock Gmail server. `POST /drafts` requires Bearer auth, returns
  `{"id":"mock-draft-id"}`. `GET /__count` exposes the draft counter
  for test assertions. Builds clean with `go build`.
- `tests/e2e/mock-host/main.go` + `go.mod` + `README.md` — minimal
  native-messaging host stub. Sends one `ready` message (Chrome Native
  Messaging framing: 4-byte LE length prefix + JSON), then blocks on
  stdin until EOF. Builds clean with `go build`.
- `tests/e2e/fixtures-v2.ts` — new Playwright fixtures file alongside
  the existing `fixtures.ts` (not modified). Exports: `startMockGmail`,
  `writeNativeManifest`, `unregisterNativeManifest`, `writeHostWrapper`,
  and the `test`/`expect` with `extensionContext`, `extensionId`, and
  `popupPage` fixtures. Implements Patterns A/B/C/D from
  `04-E2E-SPIKE.md`.
- `tests/e2e/happy-path.spec.ts` (E2E-03) — T1 test: drop fixture JSON
  in per-test `GOMAPI_WATCH_DIR` → real Go host picks it up → popup
  renders email → trigger draft → assert `mock-gmail /__count` >= 1.
- `tests/e2e/install-ux.spec.ts` (E2E-04) — T2 test: no manifest →
  `InstallPrompt` visible → write manifest pointing at mock-host →
  trigger reconnect via popup-side `chrome.runtime.sendMessage` → poll
  for prompt to disappear. Toast NOT asserted per PHASE-4-FINDING-01
  (documented bug: toast cannot fire on reconnect).
- `.github/workflows/e2e.yml` — `windows-latest` workflow. Steps:
  checkout, setup-node 20, setup-go 1.21, npm ci, build native host,
  build extension, build both mock servers, install Playwright browsers,
  run the specs, upload report + traces on failure.
- `.planning/phases/04-test-suite-completeness-e2e/04-E2E-SPIKE.md`
  (E2E-05) — research deliverable covering 6 known failure modes, 5
  stable wait patterns (A–E), retry strategy, runner-image workarounds,
  and 5 unresolved risks that the first CI run must validate.

## Verification performed on executor host

- `cd tests/e2e/mock-gmail && go build -o mock-gmail.exe .` — built
  successfully.
- `cd tests/e2e/mock-host && go build -o mock-host.exe .` — built
  successfully.
- `npx playwright test --config tests/e2e/playwright.config.ts --list`
  — lists 8 tests (6 pre-existing + 2 new: `happy-path.spec.ts` +
  `install-ux.spec.ts`). Files parse cleanly.
- **NOT verified on executor host:** actual Playwright browser run.
  Chromium is not installed on the sandbox and the native host would
  need to be built from source each time. The first `windows-latest`
  CI run in `.github/workflows/e2e.yml` is the authoritative
  verification.

## Acceptance criteria verification

All grep patterns from `04-04-PLAN.md` match the committed files.
Playwright's own test lister confirms both specs parse.

## Known limitations & deferred items

- **`waitForTimeout` audit:** `happy-path.spec.ts` uses no
  `waitForTimeout`. `install-ux.spec.ts` uses no `waitForTimeout`. Both
  rely on `expect.poll` for correctness.
- **Happy-path test includes a `test.skip`** when
  `tests/fixtures/simple-email.json` is not present — the fixture
  exists in the current repo so the skip is defensive.
- **Install-ux test includes a `test.skip`** when `mock-host.exe` is
  not built — the CI workflow builds it before running tests so the
  skip only triggers on manual local runs that forgot `go build`.
- **E2E-05 follow-up:** after the first green CI run, capture real
  `chrome.runtime.lastError.message` strings from the install-UX spec
  and update `src/extension/src/__fixtures__/chrome-errors.ts` if they
  differ from the Chromium-source seed values.
- **PHASE-4-FINDING-01 impact on E2E-04:** the install-UX test asserts
  the InstallPrompt disappears but does NOT assert the success toast
  appears, because the toast bug means it doesn't. When the bug is
  fixed, add an `expect(page.getByText(/host installed/i)).toBeVisible()`
  assertion.
