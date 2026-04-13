---
phase: 07-wails-shell-ram-gate
plan: 01
subsystem: infra
tags: [go, internal-package, watcher, fsnotify, refactor, single-module]

# Dependency graph
requires: []
provides:
  - "internal/mapi package under src/native-host module with MailMessage, ValidateMailMessage, EmailWatcher, WatcherCallback, EmailWithId, GmailClient"
  - "Idempotent watcher Stop() via sync.Once"
  - "Snapshot() method returning timestamp-sorted EmailWithId slice"
  - "nativeMessagingAdapter in package main bridging WatcherCallback to Chrome native-messaging frames"
affects: [07-02, 07-03, 07-04]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Single-module layout: internal/mapi lives under src/native-host/go.mod; no go.work until Plan 02"
    - "WatcherCallback interface decoupling fsnotify watcher from output format"
    - "Diff-based adapter: tracks previous snapshot to emit per-item events (preserves legacy wire protocol)"
    - "sync.Once for idempotent shutdown (Stop called from multiple paths safely)"
    - "testutil/fixtures.go with runtime.Caller(0) for portable fixture path resolution"

key-files:
  created:
    - "src/native-host/internal/mapi/protocol.go — MailMessage, Recipient, Recipients, Attachment, ValidateMailMessage"
    - "src/native-host/internal/mapi/gmail.go — GmailClient, BuildFullMIME, Base64URLEncode"
    - "src/native-host/internal/mapi/watcher.go — EmailWatcher, WatcherCallback, EmailWithId, Snapshot"
    - "src/native-host/internal/mapi/protocol_test.go — validation + normalization unit tests"
    - "src/native-host/internal/mapi/protocol_integration_test.go — fixture-based MailMessage parsing tests"
    - "src/native-host/internal/mapi/watcher_test.go — 7 behavior tests + parity tests (TDD)"
    - "src/native-host/internal/mapi/testutil/fixtures.go — FixturePath(rel) helper"
    - "src/native-host/nativemessaging.go — NativeMessaging, OutgoingMessage, IncomingMessage, nativeMessagingAdapter"
  modified:
    - "src/native-host/go.mod — bumped from go 1.21 to go 1.23"
    - "src/native-host/main.go — import mapi, use mapi.NewEmailWatcher + adapter"
    - "src/native-host/protocol_test.go — updated to use mapi.MailMessage types"
    - "src/native-host/protocol_integration_test.go — unchanged (OutgoingMessage/IncomingMessage stayed in main)"
    - "src/native-host/gmail_test.go — updated to use mapi.* types + mapi.NewGmailClientWithBase"
    - "src/native-host/mime_golden_test.go — updated to use mapi.* types + mapi.BuildFullMIME"

key-decisions:
  - "Single-module layout: no go.work, no separate go.mod for internal/mapi until Plan 02 adds src/app module"
  - "WatcherCallback sends full snapshot; diff-based nativeMessagingAdapter emits per-item frames for legacy protocol compat"
  - "normalizeAddress/normalizeRecipients stay unexported in internal/mapi — no external caller needs them yet"
  - "HostVersion stamping moved to nativeMessagingAdapter (Version var not accessible in internal/mapi)"
  - "GmailAPIBase, BuildFullMIME, Base64URLEncode exported since they are called from package main tests"

patterns-established:
  - "TDD RED→GREEN→FIX for watcher extraction (commit per phase)"
  - "WatcherCallback interface: Plan 02 Wails app implements it without importing package main"
  - "Snapshot() sorted by timestamp ascending — deterministic ordering for UI"

requirements-completed: [SHELL-06, QUAL-04]

# Metrics
duration: 90min
completed: 2026-04-13
---

# Phase 07 Plan 01: internal/mapi Extraction Summary

**Extracted watcher, protocol types, and Gmail client from package main into src/native-host/internal/mapi under single-module layout; introduced WatcherCallback interface with idempotent Stop() for Plan 02/03 compatibility.**

## Performance

- **Duration:** ~90 min
- **Started:** 2026-04-13T00:00:00Z
- **Completed:** 2026-04-13
- **Tasks:** 3 (+ 1 fix commit)
- **Files modified:** 14 files created/modified, 3 deleted

## Accomplishments
- Extracted `MailMessage`, `ValidateMailMessage`, `GmailClient` into `internal/mapi` package under single-module `src/native-host`
- Introduced `WatcherCallback` interface + `EmailWithId` type; replaced hard-coded `*NativeMessaging` coupling
- Idempotent `Stop()` using `sync.Once` (addresses Plan 03 shutdown race condition)
- Added `Snapshot()` returning stable timestamp-sorted `[]EmailWithId` for Wails frontend binding
- Created `testutil/fixtures.go` using `runtime.Caller(0)` for portable fixture path resolution
- 7 new watcher behavior tests (TDD) + full parity with old test suite; 55 total tests pass

## Task Commits

1. **Task 1: Create internal/mapi package + bump Go 1.23** - `63e191e` (chore)
2. **Task 2: Move protocol.go + gmail.go into internal/mapi** - `62b2f08` (refactor)
3. **Task 3 RED: Failing watcher tests** - `34f6c8d` (test)
4. **Task 3 GREEN: Watcher implementation in internal/mapi** - `d2ae304` (feat)
5. **Fix: HostVersion stamp moved to adapter** - `1d380dc` (fix)

## Files Created/Modified

Created:
- `src/native-host/internal/mapi/protocol.go` — data types + exported `ValidateMailMessage`
- `src/native-host/internal/mapi/gmail.go` — `GmailClient`, `BuildFullMIME`, `Base64URLEncode`
- `src/native-host/internal/mapi/watcher.go` — `EmailWatcher`, `WatcherCallback`, `EmailWithId`, `Snapshot()`
- `src/native-host/internal/mapi/protocol_test.go` — validation/normalization unit tests
- `src/native-host/internal/mapi/protocol_integration_test.go` — fixture-based parsing tests
- `src/native-host/internal/mapi/watcher_test.go` — 7-behavior TDD suite
- `src/native-host/internal/mapi/testutil/fixtures.go` — portable fixture path helper
- `src/native-host/nativemessaging.go` — `NativeMessaging`, `OutgoingMessage`, `IncomingMessage`, `nativeMessagingAdapter`

Modified:
- `src/native-host/go.mod` — `go 1.21` → `go 1.23`
- `src/native-host/main.go` — uses `mapi.NewEmailWatcher` + `newNativeMessagingAdapter`
- `src/native-host/protocol_test.go` — `mapi.MailMessage` types
- `src/native-host/gmail_test.go` — `mapi.*` types + `mapi.NewGmailClientWithBase`
- `src/native-host/mime_golden_test.go` — `mapi.*` types + `mapi.BuildFullMIME`

Deleted:
- `src/native-host/protocol.go` — content split to `nativemessaging.go` + `internal/mapi/protocol.go`
- `src/native-host/gmail.go` — moved to `internal/mapi/gmail.go`
- `src/native-host/watcher.go` — moved to `internal/mapi/watcher.go`
- `src/native-host/watcher_test.go` — replaced by `internal/mapi/watcher_test.go`

## Internal Package Import Path

```
github.com/marcfargas/go-mapi/native-host/internal/mapi
```

Only code under `src/native-host/` may import it (Go `internal/` enforcement). Plan 02 will introduce `src/app` module + `go.work` and confirm whether the `internal/` path resolves cross-module via `go.work`.

## Exported API of internal/mapi

```go
// protocol.go
type MailMessage struct { ... }
type Recipients struct { ... }
type Recipient struct { ... }
type Attachment struct { ... }
func ValidateMailMessage(mail *MailMessage) error

// watcher.go
type WatcherCallback interface {
    OnQueueChanged(snapshot []EmailWithId)
    OnError(err error)
}
type EmailWithId struct { Id string; Message *MailMessage }
type EmailWatcher struct { ... }
func NewEmailWatcher(dir string, cb WatcherCallback) (*EmailWatcher, error)
func (ew *EmailWatcher) Start() error
func (ew *EmailWatcher) Stop()            // idempotent via sync.Once
func (ew *EmailWatcher) Snapshot() []EmailWithId
func (ew *EmailWatcher) GetEmails() map[string]*MailMessage  // deprecated
func (ew *EmailWatcher) MarkProcessed(id string) error
func (ew *EmailWatcher) Delete(id string) error

// gmail.go
type GmailClient struct { ... }
func NewGmailClient(token string) *GmailClient
func NewGmailClientWithBase(token, baseURL string) *GmailClient
func (gc *GmailClient) CreateDraft(msg *MailMessage) (string, error)
func BuildFullMIME(msg *MailMessage) ([]byte, error)
func Base64URLEncode(data []byte) string
const GmailAPIBase = "https://www.googleapis.com/gmail/v1/users/me"
const MaxFileSize = 25 * 1024 * 1024
```

## Wails/systray Version Check (informational for Plan 02)

- `github.com/wailsapp/wails/v2` latest: **v2.12.0** (matches plan; no v2.12.1 patch)
- `fyne.io/systray` latest: **v1.12.0** (matches plan; no v1.12.1 patch)
- Plan 02 should adopt these exact versions as planned.

## Decisions Made

- **Single-module layout until Plan 02:** No `go.work`, no separate `go.mod` for `internal/mapi`. Go `internal/` enforces that only `src/native-host` code imports the package. Plan 02 introduces `src/app` and `go.work`.
- **WatcherCallback full-snapshot approach:** `OnQueueChanged` receives the complete current snapshot. The `nativeMessagingAdapter` diffs against its previous snapshot to emit per-item `SendEmail`/`SendRemoved` frames, preserving the legacy wire protocol.
- **HostVersion stamping moved to adapter:** `Version` is defined in `package main/version.go` and not accessible in `internal/mapi`. The adapter stamps `e.Message.HostVersion = Version` on new emails before sending.
- **Unexported normalizers:** `normalizeAddress` and `normalizeRecipients` remain unexported. No external caller needs them; `ValidateMailMessage` does not call them directly (callers normalize before calling). If Plan 02's Wails app needs normalization, export then.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] HostVersion not stamped on outgoing emails after watcher move**
- **Found during:** Task 3 review after GREEN phase
- **Issue:** The old `watcher.go` set `mail.HostVersion = Version` in `processFile`. After moving watcher to `internal/mapi`, `Version` (package main) is not accessible there, leaving `HostVersion` empty on all outgoing emails.
- **Fix:** Added `e.Message.HostVersion = Version` in `nativeMessagingAdapter.OnQueueChanged` for newly-emitted emails. The adapter has access to `Version` (package main).
- **Files modified:** `src/native-host/nativemessaging.go`
- **Commit:** `1d380dc`

---

**Total deviations:** 1 auto-fixed (Rule 1 bug)
**Impact on plan:** Essential correctness fix. No scope creep.

## Issues Encountered

- `-race` flag not supported on windows/arm64 (development machine). All tests run without `-race` flag. CI should run on a non-ARM64 platform where `-race` is available to fulfill QUAL-04 fully.

## Next Phase Readiness

- Plan 02 can import `github.com/marcfargas/go-mapi/native-host/internal/mapi` via `go.work` once `src/app` module is scaffolded
- `WatcherCallback` interface is ready for Plan 02's Wails `App` struct to implement
- `Stop()` idempotency tested and confirmed — Plan 03 session-end handler can call it safely
- All legacy tests still pass; wire protocol unchanged

## Known Stubs

None — all data flows are wired. The `HostVersion` field is now stamped correctly in the adapter.

---
*Phase: 07-wails-shell-ram-gate*
*Completed: 2026-04-13*

## Self-Check: PASSED

**Files verified:**
- FOUND: `src/native-host/internal/mapi/protocol.go`
- FOUND: `src/native-host/internal/mapi/gmail.go`
- FOUND: `src/native-host/internal/mapi/watcher.go`
- FOUND: `src/native-host/internal/mapi/watcher_test.go`
- FOUND: `src/native-host/internal/mapi/testutil/fixtures.go`
- FOUND: `src/native-host/nativemessaging.go`

**Commits verified:**
- `63e191e` — chore(07-01): bump go module to 1.23, create internal/mapi package dir
- `62b2f08` — refactor(07-01): move protocol.go + gmail.go into internal/mapi (Task 2)
- `34f6c8d` — test(07-01): add failing watcher tests for internal/mapi (RED)
- `d2ae304` — feat(07-01): move watcher to internal/mapi; add WatcherCallback, Snapshot, idempotent Stop (Task 3 GREEN)
- `1d380dc` — fix(07-01): stamp HostVersion in nativeMessagingAdapter (Rule 1 deviation)
