# Phase 4: Test-Suite Completeness + E2E - Context

**Gathered:** 2026-04-10
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver the regression safety net for v2.0.0: every high-blast-radius area
across Go, C++, TypeScript, and the end-to-end seam must be caught by CI
before it ships. Scope is the 18 requirements GOTEST-01..04, CPPTEST-01..03,
TSTEST-01..05, E2E-01..06.

**In scope:** Go `httptest.Server` + golden-file tests for `gmail.go` /
`buildFullMIME()`, a `-race` nightly workflow, a risk-based punch list of Go
gaps, doctest wiring for the extracted `message_converter`, `vitest-chrome`
adoption + unit/component tests for `hostDetector` / `hostVersion` /
`InstallPrompt` / the service-worker `HOST_STATE` broadcast, Playwright
`launchPersistentContext` happy-path and install-UX tests, a mock Gmail
server under `tests/e2e/mock-gmail/`, a Playwright-flakiness spike, and a
`chrome-errors.ts` fixture file seeded from the Chromium source.

**Out of scope per REQUIREMENTS.md:** numeric coverage thresholds
(the 80% gate was explicitly rejected), mutation testing, real Gmail API in
per-PR E2E, Jest / jest-chrome / testify / mockgen adoption, and any
refactor of Phase 1/2/3 production source. Pre-existing staticcheck gaps in
`gmail.go` / `main.go` / `watcher.go` are deferred tech debt and stay
deferred.

</domain>

<decisions>
## Implementation Decisions

Most test decisions are locked by REQUIREMENTS.md and the task brief — the
decisions captured here are the things the brief leaves to planner
discretion: test organization, fixture layout, the E2E-05 spike scope, and
the TSTEST-05 testability workaround.

### Test organization
- **D-01:** Go tests stay co-located with the production package
  (`src/native-host/gmail_test.go`, `src/native-host/mime_golden_test.go`).
  Fixtures live under `src/native-host/testdata/mime/`, which is the Go
  stdlib convention for golden files.
- **D-02:** Extension tests live under `src/extension/src/**/__tests__/`
  (per the existing convention in `popup/__tests__/`). New directories:
  `src/extension/src/lib/__tests__/` and
  `src/extension/src/background/__tests__/`.
- **D-03:** C++ doctest lives in `src/interceptor/tests/` (new directory —
  `test-harness` is the existing integration-style DLL exerciser and stays
  untouched). The doctest binary `message_converter_tests` is built only
  when `-DBUILD_TESTS=ON` is passed and links the existing
  `message_converter_obj` OBJECT library from `CMakeLists.txt`. A second
  test executable is preferred over adding cases to the existing harness
  because doctest's assertion style is incompatible with the hand-rolled
  `TEST_UTILS` macros in `test-harness/`.

### Fixture strategy
- **D-04:** Golden files are UTF-8 text containing the raw `buildFullMIME()`
  output byte-for-byte, with CRLF line endings preserved (RFC 2822 requires
  CRLF and the comparison must be exact). A `-update` flag regenerates all
  goldens via `flag.Bool` in the test file — this is the stdlib idiom.
- **D-05:** The multipart boundary in `buildFullMIME()` is
  `go_mapi_<pid>`, which is non-deterministic. The golden-file tests call a
  helper that normalizes the pid to a fixed placeholder (`go_mapi_PID`)
  before comparison, so goldens stay stable across runs.
- **D-06:** Attachment fixtures for golden tests use small in-memory byte
  blobs written to `t.TempDir()` inside the test, not committed binary
  files. This keeps the repo clean and avoids binary diff noise on PRs.
- **D-07:** Real `chrome.runtime.lastError.message` fixtures live at
  `src/extension/src/__fixtures__/chrome-errors.ts` and are seeded from
  Chromium source with the two known substrings
  (`"Specified native messaging host not found."` and
  `"Access to the specified native messaging host is forbidden."`). A
  header comment flags that real-capture replacement happens during the
  first green E2E run (E2E-06).

### TSTEST-05 testability workaround
- **D-08:** `transitionHostState` in `service-worker.ts` is a closure over
  module-level state (`hostState`, `hostErrorMessage`, `hasShownInstalledToast`).
  The task brief forbids modifying Phase 1/2/3 source code. Tests therefore
  exercise the transition logic indirectly by importing the service-worker
  module once (triggering its `loadState → connectToNativeHost` bootstrap
  under the chrome mock), driving state via port `onMessage` / `onDisconnect`
  callbacks captured from the mock, and asserting on `chrome.runtime.sendMessage`
  call arguments. The MISSING→READY edge is the high-value assertion.
- **D-09:** `vitest-chrome` is added alongside the existing hand-rolled
  `src/extension/src/test/mocks/chrome.ts`. The existing mock stays because
  its targeted helpers (`mockAuthTokenSuccess`, `createMockPort`) are
  already consumed by `protocol.integration.test.ts`. New tests use
  `vitest-chrome` directly where it's simpler; the setup file extends the
  existing `vi.stubGlobal('chrome', ...)` with `chrome.storage.session`,
  `chrome.alarms`, and `chrome.notifications` stubs that the service worker
  needs but the current mock doesn't expose.

### Race detection job
- **D-10:** The nightly `-race` job lives in a separate workflow file
  (`.github/workflows/go-race-nightly.yml`) — distinct from
  `build.yml` so the per-PR feedback loop stays fast. Schedule:
  `cron: '0 3 * * *'` (03:00 UTC) plus `workflow_dispatch` for manual runs.
  Runs on `windows-latest` with `CGO_ENABLED=1` (required for `-race` on
  Windows with MinGW) and `go test -race ./...` in `src/native-host/`.

### C++ test wiring
- **D-11:** `CMakeLists.txt` already has `option(BUILD_TESTS "..." ON)` and
  conditionally adds the `test-harness` subdirectory. A second
  `add_subdirectory(tests)` block (new directory) is added under the same
  `BUILD_TESTS` guard. The new `tests/CMakeLists.txt` creates
  `message_converter_tests` executable linked against
  `$<TARGET_OBJECTS:message_converter_obj>` (zero recompile, ABI-identical
  to the DLL target).
- **D-12:** doctest is vendored as a single `doctest.h` header committed to
  `src/interceptor/tests/doctest.h` — this is the upstream-recommended
  approach for small C++ projects and avoids a submodule. LGPL-3.0 is
  compatible with doctest's MIT license (MIT → LGPL is one-way
  compatible).
- **D-13:** CI integration extends `build-interceptor` in `build.yml`: the
  `build.ps1` invocation already passes `-Tests` which propagates
  `-DBUILD_TESTS=ON`, so the only new line is a `ctest --output-on-failure`
  step after the build. No new workflow file.

### E2E scope
- **D-14:** The new E2E tests (`happy-path.spec.ts`, `install-ux.spec.ts`)
  reuse the existing `fixtures.ts` pattern (persistent context, extension
  load, native-host registration) but bypass the test harness. Fixture
  JSON is dropped directly into a per-test watch dir via `GOMAPI_WATCH_DIR`
  (FOUND-04), and the Go host is launched by Chrome via the native-messaging
  manifest rewritten per-test to pass `--gmail-api-base=<mock-url>`.
- **D-15:** The mock Gmail server (`tests/e2e/mock-gmail/main.go`) is a
  stdlib-only Go program that handles `POST /drafts`, returns a synthetic
  `{"id": "mock-draft-id"}` JSON body, and logs requests to stderr. It is
  launched as a child process by the Playwright setup and its URL is
  injected into the per-test native-messaging manifest via the host's
  `--gmail-api-base` flag.
- **D-16:** E2E-04 install-UX test does NOT register the native-messaging
  manifest before launching Chromium. The test asserts that `InstallPrompt`
  appears, then writes the manifest pointing at `tests/e2e/mock-host/`
  (a minimal Go program that sends `READY` on stdin and exits cleanly),
  forces the reconnect alarm via `chrome.runtime.sendMessage({action:'reconnect'})`,
  and asserts the state transition.
- **D-17:** The E2E-01 workflow (`.github/workflows/e2e.yml`) runs on
  `windows-latest` only and depends on `build.yml` artifacts (extension
  dist + native host binary) via `workflow_run` OR rebuilds them
  directly — planner picks whichever is simpler. Runs on push to main/develop,
  pull_request, and `workflow_dispatch`.

### E2E-05 spike scope
- **D-18:** The spike is a research deliverable only — a single markdown
  file `04-E2E-SPIKE.md` documenting:
  - Known failure modes of `launchPersistentContext` on `windows-latest`
    (service worker bootstrap races, extension ID timing, registry write
    delays).
  - Stable wait patterns (`waitForEvent('serviceworker')`, explicit
    `waitForLoadState('networkidle')`, retry loops around
    `connectNative`).
  - Runner-image workarounds (setting `CHROME_PATH`, disabling Defender
    real-time scanning on the test dir).
  - A recommended retry strategy (Playwright `retries: 2` on CI only).
  - The patterns discovered MUST be applied back into `happy-path.spec.ts`
    and `install-ux.spec.ts` before they are committed.

### Claude's Discretion
- Exact table-driven test case names and helper function names inside each
  test file.
- Test comment wording and file-level doc comments.
- Whether to split C++ tests across multiple .cpp files (one per
  concern) or keep them in a single `message_converter_tests.cpp`.
- Playwright test helper internal structure (page objects vs inline
  selectors).
- The exact list of grep-verifiable acceptance criteria in each PLAN.md.

</decisions>

<canonical_refs>
## Canonical References

**Downstream planners MUST read these before planning or implementing.**

### Phase scope + requirements
- `.planning/ROADMAP.md` §"Phase 4: Test-Suite Completeness + E2E" — goal,
  success criteria, dependencies on Phases 1/2/3.
- `.planning/REQUIREMENTS.md` GOTEST-01..04, CPPTEST-01..03, TSTEST-01..05,
  E2E-01..06 (lines 49–77) — full requirement text.

### Phase 1 foundations this phase consumes
- `.planning/phases/01-foundation-signpath-application/01-03-SUMMARY.md` —
  FOUND-03 `GmailClient.baseURL` injection, `NewGmailClientWithBase`
  constructor.
- `.planning/phases/01-foundation-signpath-application/01-04-SUMMARY.md` —
  FOUND-04 `GOMAPI_WATCH_DIR` env var and `--gmail-api-base` CLI flag with
  CLI > env > default precedence.
- `.planning/phases/01-foundation-signpath-application/01-05-SUMMARY.md` —
  FOUND-05 `message_converter` extraction into an OBJECT library.
- `src/native-host/gmail.go` — `NewGmailClientWithBase` constructor (line ~39).
- `src/native-host/main.go` — `buildFullMIME` lives here? (actually in
  `gmail.go` line ~108).
- `src/native-host/watcher.go` — retry paths, validator edges.
- `src/interceptor/message_converter.{h,cpp}` — extracted conversion module.
- `src/interceptor/CMakeLists.txt` — `BUILD_TESTS=ON` option + `message_converter_obj`.

### Phase 2 foundations this phase tests
- `src/extension/src/lib/hostDetector.ts` — `HostState` union, `classifyLastError`,
  `classifyReadyMessage`, `MISSING_HOST_SUBSTRING` constant.
- `src/extension/src/lib/hostVersion.ts` — `MIN_SUPPORTED_HOST_VERSION`,
  `compareHostVersion`, `isHostVersionSupported`.
- `src/extension/src/popup/InstallPrompt.tsx` — `INSTALLER_DOWNLOAD_URL`
  constant, MISSING/OUTDATED/ERROR variants.
- `src/extension/src/background/service-worker.ts` — `transitionHostState`,
  `hasShownInstalledToast` flag, HOST_STATE / HOST_INSTALLED_TOAST broadcasts.

### Phase 3 foundations this phase tests
- `src/installer/go-mapi.iss` + `.github/workflows/installer-smoke.yml` —
  already validated in Phase 3 `installer-smoke.yml`; E2E does NOT re-test
  installer smoke, only the extension install-UX flow.

### Project conventions
- `CLAUDE.md` §"Directory and File Location" — `_test.go` for unit,
  `_integration_test.go` for integration.
- `CLAUDE.md` §"Testing frameworks" — Vitest + Go stdlib + doctest +
  Playwright; no Jest / testify / mockgen.
- `src/extension/src/test/setup.ts` — existing vitest setup file that
  `chrome.*` stubs live in; new tests extend this, do not replace it.
- User global `verify-data-shapes.md` rule — every test that reads
  structured data (JSON, Go structs, C++ structs) reads the real schema
  before assuming shape.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `src/native-host/watcher_test.go` — already covers validator happy paths,
  recipient address normalization, `generateID`, `EmailWatcher` creation +
  `processExistingFiles` + `MarkProcessed` + `Delete` + invalid-file
  handling + non-JSON file filtering. GOTEST-04 punch list accounts for
  this — most watcher territory is already covered.
- `src/native-host/protocol_test.go` + `protocol_integration_test.go` —
  existing protocol framing tests. Not in scope for this phase.
- `src/extension/src/test/mocks/chrome.ts` — existing chrome mock with
  `runtime.connectNative`, `runtime.sendMessage`, `identity.getAuthToken`,
  `action`, `tabs`, `storage.local`, `storage.sync`. Missing:
  `storage.session`, `alarms`, `notifications`. New tests need these.
- `src/extension/src/test/setup.ts` — registers the chrome mock globally
  via `vi.stubGlobal`. `vitest-chrome` integration extends this file.
- `src/extension/src/popup/__tests__/EmailList.test.tsx` and
  `EmailDetail.test.tsx` — existing RTL component tests; follow their
  style for `InstallPrompt` tests.
- `tests/e2e/fixtures.ts` — existing `extensionContext` / `extensionId` /
  `popupPage` Playwright fixtures using `launchPersistentContext`. New
  tests build on this pattern.
- `tests/e2e/extension.spec.ts` — existing smoke test pattern; new tests
  follow the same `test.describe` + custom fixtures style.
- `src/interceptor/CMakeLists.txt` — `BUILD_TESTS` option, `message_converter_obj`
  OBJECT library, conditional `add_subdirectory(test-harness)`. New
  doctest target slots in next to `test-harness` under the same guard.

### Established Patterns
- Go tests use `testing.T` + `t.TempDir()` + stdlib only (no testify).
- Go golden-file tests use `flag.Bool("update", ...)` + `os.ReadFile` /
  `os.WriteFile` with CRLF-preserving comparison.
- C++ test-harness uses hand-rolled `TEST_UTILS` macros — doctest is a
  clean break to a dedicated test runner. No pattern to follow; doctest
  documentation is the reference.
- Vitest component tests use `@testing-library/react` `render` +
  `screen.getByRole` / `getByText`. Snapshots are discouraged in this
  codebase (no `.snap` files found) — use explicit assertions.
- Playwright fixtures export `test` and `expect` from a local `fixtures.ts`
  and use `test.describe` + custom fixture names.
- GitHub Actions workflows use `windows-latest` for everything touching
  Go or MAPI, Node 20 for the extension, Inno Setup 6 for the installer.

### Integration Points
- `httptest.Server` → `NewGmailClientWithBase(token, baseURL)` → Go tests
  hit `baseURL/drafts` without touching the real Gmail API.
- `GOMAPI_WATCH_DIR` → per-test temp dir → E2E tests drop fixture JSON
  without touching `%TEMP%\go-mapi\`.
- `--gmail-api-base` → mock Gmail HTTP server URL → E2E tests inject via
  the per-test native-messaging manifest (manifest path is rewritten
  per-test to include the flag in the `path` + `args`).
- `vitest-chrome` → `vi.stubGlobal('chrome', ...)` in setup.ts → TS tests
  drive chrome.* callbacks without a real browser.
- `doctest.h` → `message_converter_obj` OBJECT library → C++ tests compile
  against the same translation units as the DLL, no recompile.
- `ctest` → `message_converter_tests` executable → CI runs on `windows-latest`
  as part of `build-interceptor` in `build.yml`.

</code_context>

<specifics>
## Specific Ideas

- The task brief explicitly flags that `CPPTEST-02` mentions function
  names `ConvertMessageFromMapi` / `ConvertMessageFromMapiW`, but the
  actual exports in `message_converter.h` are `ConvertAnsiMessage` and
  `ConvertWideMessage`. The tests use the real names (the requirement text
  is a descriptive wording mismatch, not a source bug).
- `buildFullMIME()` hardcodes the multipart boundary `go_mapi_<pid>`. The
  golden-file helper normalizes this to `go_mapi_PID` before comparison
  (D-05) — tests must not crash or flake on different pids.
- `AnsiToUtf8` in `message_converter.cpp` uses `CP_ACP` which depends on
  the system's active ANSI code page. ANSI-path tests therefore only use
  pure ASCII input. Non-ASCII testing lives on the Wide/UTF-16 path where
  `WideToUtf8` uses `CP_UTF8` deterministically.
- The task brief says "don't modify Phase 1/2/3 source code unless a test
  reveals a bug". The TSTEST-05 testability workaround (D-08) honors this
  by testing `transitionHostState` via side-effect observation (the
  `chrome.runtime.sendMessage` call arguments) rather than by extracting
  a pure helper.
- The E2E-06 fixture file is created NOW (seeded from known Chromium
  strings), not deferred until the first E2E run, because TSTEST-02 imports
  it and must be runnable on any dev host — not just CI.

</specifics>

<deferred>
## Deferred Ideas

- **Real `lastError.message` capture from a live E2E run** — seeded
  fixtures ship now; the first successful CI E2E run can update the file
  with captured strings if they differ. The file header documents this.
- **Mutation testing** — explicitly out of scope per REQUIREMENTS.md.
- **Coverage threshold gate** — explicitly out of scope per REQUIREMENTS.md.
- **Real Gmail API E2E** — mocked via `httptest`; real-API smoke is a
  v2.1.0 idea (SMOKE-01 in REQUIREMENTS.md "v2 Requirements").
- **Testify / mockgen / jest-chrome migration** — explicitly out of scope.
- **Refactoring `service-worker.ts` to extract `transitionHostState` as a
  pure helper** — would simplify TSTEST-05 significantly but is out of
  scope per the no-source-modifications rule. If Phase 4 test writing
  reveals this as load-bearing, flag in `04-FINDINGS.md` as future work.
- **Fixing pre-existing staticcheck issues in `gmail.go` / `main.go` /
  `watcher.go`** — flagged as deferred tech debt in the Phase 1 handoff,
  not in scope for Phase 4.
- **CPPTEST-02 testing of `ConvertAnsiMessage` non-ASCII paths** — skipped
  because `CP_ACP` makes the result depend on the runner's ANSI code page
  and would flake. Non-ASCII coverage lives on the Wide path.

</deferred>

---

*Phase: 04-test-suite-completeness-e2e*
*Context gathered: 2026-04-10*
