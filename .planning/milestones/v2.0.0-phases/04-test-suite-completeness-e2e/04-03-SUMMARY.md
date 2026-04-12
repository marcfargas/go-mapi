---
phase: 04-test-suite-completeness-e2e
plan: 03
type: execute
wave: 3
status: completed
completed: 2026-04-10
requirements: [TSTEST-01, TSTEST-02, TSTEST-03, TSTEST-04, TSTEST-05, E2E-06]
---

# Wave 3 Summary — TypeScript / Extension Test Completeness

## What shipped

- `vitest-chrome@^0.1.0` — added as a devDependency in
  `src/extension/package.json`. Lockfile updated in the same commit per
  the global lockfile-discipline rule.
- `src/extension/src/test/mocks/chrome.ts` — extended with
  `storage.session`, `alarms`, and `notifications` surface areas.
  Existing `runtime` / `identity` / `action` / `tabs` /
  `storage.{local,sync}` stubs unchanged so
  `protocol.integration.test.ts` continues to pass.
  `resetChromeMocks()` updated to clear the new mock calls.
- `src/extension/src/__fixtures__/chrome-errors.ts` (E2E-06) — seeded
  from the Chromium source tree with `MISSING_HOST_CHROMIUM`,
  `ACCESS_FORBIDDEN`, and `UNKNOWN_HOST_ERROR` constants. Header comment
  flags that real-capture replacement happens during the first green
  E2E run.
- `src/extension/src/lib/__tests__/hostDetector.test.ts` (13 tests) —
  `classifyLastError` against every fixture string + undefined + empty
  + substring-wrap case, `classifyReadyMessage` happy path + dead-branch
  + OUTDATED future activation.
- `src/extension/src/lib/__tests__/hostVersion.test.ts` (14 tests) —
  `compareHostVersion` equal / less / greater / short-segment /
  non-numeric; `isHostVersionSupported` undefined / empty / dead branch
  / above / below / malformed.
- `src/extension/src/popup/__tests__/InstallPrompt.test.tsx` (11 tests)
  — MISSING heading + button label + URL + SmartScreen copy, OUTDATED
  heading + button label + URL, ERROR heading + errorMessage surface +
  recovery button + degenerate no-error-message variant.
- `src/extension/src/background/__tests__/service-worker.test.ts` (6
  tests) — initial PROBING broadcast, MISSING classification on
  disconnect, ERROR classification on unknown disconnect,
  HOST_STATE payload shape, and two PHASE-4-FINDING-01 regression tests
  that lock the current (buggy) HOST_INSTALLED_TOAST behavior.

## Verification performed on executor host

```
cd src/extension
npx tsc --noEmit       # clean
npm run lint           # clean
npm run test:run       # 7 test files, 87 tests, all green
```

Breakdown: 3 existing test files (43 tests) + 4 new test files (44 tests).

## Finding surfaced during test writing

**PHASE-4-FINDING-01** — `HOST_INSTALLED_TOAST` (EXT-06) never fires in
practice because `transitionHostState('PROBING')` runs on every
reconnect, so the `MISSING → READY` guard is never hit — the reachable
sequence is always `MISSING → PROBING → READY`. Captured in detail in
`04-FINDINGS.md` with reproducer test and suggested fix. Not fixed in
Phase 4 per the no-source-modifications scope rule.

## Acceptance criteria verification

All grep patterns from `04-03-PLAN.md` match the committed files. The
TSTEST-05 acceptance criterion is met via the current-behavior-locking
tests (clause "or tests are explicitly marked with a documented reason,
in which case 04-FINDINGS.md captures the limitation") — no
`test.todo`/`test.skip` was needed because the tests fully run green
against the committed (buggy) source.
