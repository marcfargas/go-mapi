# GOTEST-04: Risk-Based Go Test Audit

**Requirement:** GOTEST-04 — "A risk-based test audit produces a short
punch list of remaining untested code (logging helpers, validator edge
cases, watcher retry paths) and any entries judged load-bearing are
filled; low-risk gaps are explicitly deferred with reasoning."

**Scope:** `src/native-host/` — every `.go` file in the `main` package.

**Approach:** Enumerate every top-level function and method in the
package, check whether it has a direct test, and classify the gaps by
risk. Load-bearing gaps are filled by the Wave 1 GOTEST-01/02 work above;
this audit exists to catch anything those plans miss and to explicitly
justify the deferred low-risk set.

---

## Covered (already has direct tests)

### `gmail.go`
- `NewGmailClient` — constructs via `NewGmailClientWithBase`, exercised transitively.
- `NewGmailClientWithBase` — exercised by every case in `TestGmailClient_CreateDraft` (GOTEST-01).
- `GmailClient.CreateDraft` — five direct table-driven cases: happy path, 401, 500, network failure, non-JSON response. Plus `TestGmailClient_CreateDraft_RequestBodyShape` covering the request envelope.
- `buildFullMIME` — six golden-file cases: UTF-8 subject, attachment-with-spaces, non-ASCII attachment filename, boundary-collision body, long body, empty body (GOTEST-02).
- `formatRecipients` — exercised transitively by every golden fixture with a `Recipients.To` entry.
- `mimeEncodeHeader` — exercised by the `utf8_subject` and `attachment_nonascii` goldens (encoded header output locked by fixture).
- `base64Wrap` — exercised by every golden case that encodes a body or attachment. Line-wrap behavior locked by the `long_body` fixture.
- `base64URLEncode` — exercised by `TestGmailClient_CreateDraft_RequestBodyShape` which asserts the output contains no `+/=` characters.

### `watcher.go`
- `NewEmailWatcher` — `TestEmailWatcher_Creation` asserts all three directories (watch, processed, errors) are created.
- `EmailWatcher.Start` / `Stop` — exercised by every watcher integration test.
- `EmailWatcher.GetEmails` — `TestEmailWatcher_GetEmails_Empty`, `TestEmailWatcher_ProcessExistingFiles`.
- `EmailWatcher.MarkProcessed` — `TestEmailWatcher_MarkProcessed`, `TestEmailWatcher_MarkProcessed_NotFound`.
- `EmailWatcher.Delete` — `TestEmailWatcher_Delete`, `TestEmailWatcher_Delete_NotFound`.
- `EmailWatcher.processExistingFiles` — `TestEmailWatcher_ProcessExistingFiles`, `TestEmailWatcher_IgnoresNonJSONFiles`.
- `EmailWatcher.processFile` — exercised transitively by the existing-file path; `TestEmailWatcher_InvalidFileMovedToErrors` covers the validation-error branch; `TestEmailWatcher_ProcessExistingFiles` covers the happy path.
- `EmailWatcher.moveToErrors` — exercised by `TestEmailWatcher_InvalidFileMovedToErrors`.
- `validateMailMessage` — twelve dedicated cases covering every branch: `_Valid`, `_ValidHTML`, `_MissingVersion`, `_MissingTimestamp`, `_InvalidBodyFormat`, `_EmptyBodyFormat`, `_ToRecipientMissingAddress`, `_CCRecipientMissingAddress`, `_BCCRecipientMissingAddress`, `_MultipleRecipients`, `_NoRecipients`.
- `normalizeAddress` — `TestNormalizeAddress` with 8 inputs (every prefix, empty, unknown prefix).
- `normalizeRecipients` — `TestNormalizeRecipients`.
- `generateID` — four dedicated cases: `_DifferentContent`, `_SameContentDifferentFilename`, `_Deterministic`, `_Format`.

### `protocol.go`
- `NewNativeMessaging` — exercised transitively by every NativeMessaging test.
- `NativeMessaging.Read` — `TestNativeMessaging_Read_*` (8 cases: valid, EOF, invalid JSON, oversized, truncated, plus process/delete/shutdown variants).
- `NativeMessaging.Write` — `TestNativeMessaging_Write_*` (4 cases: email, ready, removed, error).
- `NativeMessaging.SendEmail` / `SendReady` / `SendRemoved` / `SendError` — covered by the Write tests.
- Framing — `TestNativeMessagingFormat_Read`, `TestNativeMessagingFormat_Write`.
- Fixture integration — 8 `TestFixture_*` cases verifying real-world message shapes.

### `version.go`
- `Version` constant — a literal package-level variable, zero branches, consumed by `SendReady` and stamped onto `MailMessage` in the watcher. No dedicated test — the value is locked by compilation.

---

## Load-bearing gaps filled by GOTEST-01/02

All listed load-bearing gaps are filled by the Wave 1 plans:
- `CreateDraft` HTTP error paths (GOTEST-01).
- `CreateDraft` request-shape correctness (GOTEST-01 supplementary test).
- `buildFullMIME` encoding edge cases (GOTEST-02 golden fixtures).

No additional test files beyond `gmail_test.go` and `mime_golden_test.go`
are required to close load-bearing gaps.

---

## Deferred low-risk gaps

These functions are intentionally untested because the risk/reward does
not justify test code.

### Logging and plumbing (`main.go`)

- `initLogging` — File I/O wrapper around `os.OpenFile`. Silent failure
  (returns without error) is by design for a headless native-messaging
  host. Any regression here surfaces as a missing `native-host.log`, not
  as a user-facing bug. **Deferred:** too-close-to-stdlib to meaningfully
  test; exercised transitively by every integration test that writes
  through `logInfo`.
- `closeLogging` — Single-line `logFile.Close()` wrapper. **Deferred:**
  no branches to cover.
- `logInfo` / `logError` — `fmt.Fprintf` wrappers with a nil-file guard.
  **Deferred:** exercised transitively by every path that logs.
- `defaultWatchDir` — Reads `TEMP`/`TMP`/`os.TempDir()` in order. Pure
  fallback chain. **Deferred:** branch coverage here would require
  monkey-patching environment variables for minimal reward. The fallback
  is exercised by every test that does not set `GOMAPI_WATCH_DIR`.
- `parseFlags` — Uses `flag.ContinueOnError` + `io.Discard` to tolerate
  unknown args (Chrome passes the extension origin URL as argv[1]).
  **Deferred:** testing package-level globals via `os.Args` rewriting is
  fragile and the function is exercised end-to-end by every real host
  launch. The documented behavior ("tolerate unknown args, flag > env >
  default") is stable by construction.
- `main` — The entry point. **Deferred:** entry points are not unit
  tested — they are integration-tested by running the binary under
  `go-mapi-host.exe`. E2E-03 covers this path.
- `handleCreateDraft` — Three-branch guard (`msg.Token == ""`,
  `msg.Email == nil`, call `GmailClient.CreateDraft`). **Deferred:** the
  guards are trivial fall-throughs, the meaningful path is `CreateDraft`
  itself which is covered by GOTEST-01. A dedicated test would require
  mocking `NativeMessaging.Send*` and provides minimal incremental
  signal.

### Watcher internals (`watcher.go`)

- `EmailWatcher.watchLoop` — Long-running goroutine that debounces
  fsnotify events. **Deferred:** the debounce window (500ms) makes direct
  testing slow and flaky; the surrounding functions (`processFile`,
  `handleRemove`) are covered directly. The retry-with-backoff path
  inside `processFile` is documented but not directly asserted; a test
  for it would need to fake file-open-during-read which is
  platform-specific on Windows and not worth the complexity.
- `EmailWatcher.handleRemove` — Single-state-transition helper. Covered
  transitively by `TestEmailWatcher_Delete` (which calls `os.Remove`
  triggering the fsnotify event). A direct unit test would duplicate the
  Delete test.

### Protocol serialization helpers (`protocol.go`)

- `NativeMessaging.SendDraftCreated` / `SendDraftError` — Thin wrappers
  around `Write` with a fixed `OutgoingMessage` shape. **Deferred:**
  `Write` is tested; these are tag-dispatch convenience methods with no
  branches.

---

## Summary

- **Total exported/notable functions in `main` package:** ~30
- **Covered directly or transitively:** ~22
- **Load-bearing gaps filled in Wave 1:** 2 (`CreateDraft` HTTP surface +
  `buildFullMIME` encoding)
- **Deferred low-risk gaps:** ~8 (logging helpers, `defaultWatchDir`,
  `parseFlags`, `main`, `handleCreateDraft`, `watchLoop`, `handleRemove`,
  draft-send helpers)

The audit is judged complete. No further Wave 1 test files are required.
The Wave 1 GOTEST-01 and GOTEST-02 tests plus the existing `watcher_test.go`
/ `protocol_test.go` / `protocol_integration_test.go` / `gmail_test.go` /
`mime_golden_test.go` form the regression safety net for the high-blast-
radius Go surface.

---

*Audit performed: 2026-04-10 during Phase 4 Wave 1 execution*
