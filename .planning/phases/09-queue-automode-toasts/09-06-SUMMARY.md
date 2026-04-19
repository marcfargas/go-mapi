---
phase: 09-queue-automode-toasts
plan: "06"
subsystem: toast-notifications
tags: [toast, com-activator, aumid, winrt, notif-05, dev-script, windows]
dependency_graph:
  requires: [09-03, 09-04]
  provides: [NOTIF-01, NOTIF-02, NOTIF-03, NOTIF-04-dev, NOTIF-05, QUEUE-05, QUEUE-06, QUAL-03]
  affects: [src/app/app.go, src/app/automode.go, src/app/toast_windows.go, src/app/toast_shim_windows.go]
tech_stack:
  added:
    - git.sr.ht/~jackmordaunt/go-toast/v2 v2.0.3 (promoted from indirect to direct)
    - github.com/go-ole/go-ole v1.3.0 (promoted from indirect to direct)
  patterns:
    - WinRT COM VTable via go-ole (RoGetActivationFactory + QueryInterface + SyscallN)
    - Build-tag split (//go:build windows / //go:build !windows)
    - Closure-scoped knownIds map for arrival-only toast diffing (NOTIF-04 anti-spam)
    - MustQueryInterface replaced with QueryInterface (error return, no panic in tests)
key_files:
  created:
    - src/app/toast.go
    - src/app/toast_windows.go
    - src/app/toast_shim_windows.go
    - src/app/toast_stub.go
    - src/app/toast_test.go
    - scripts/register-dev-aumid.ps1
    - scripts/unregister-dev-aumid.ps1
  modified:
    - src/app/app.go (initToasts in startup, knownIds arrival detection, handleToastAction, toast calls in CreateDraftForID/DismissEmail)
    - src/app/automode.go (emitErrorToast/emitDraftSuccessToast in draftOne, emitSummaryInvalidGrantToast on invalid_grant in drain)
    - src/app/go.mod (deps promoted to direct)
decisions:
  - "displayFrom() uses Recipients.To[0] not From field — MailMessage models outgoing emails (no From field)"
  - "All MustQueryInterface replaced with QueryInterface to return errors instead of panicking in test environments"
  - "knownIds seeded at startup from initial snapshot to suppress toast spam on restart (NOTIF-04)"
  - "emitDraftSuccessToast called on every success path regardless of isVisible() — the function itself gates on D-11"
  - "go.sum not separately committed — go mod tidy touched it but no net change in hashes (already present as indirect)"
metrics:
  duration: "~4 hours (across two sessions)"
  completed: "2026-04-19"
  tasks_completed: 3
  tasks_total: 4
  files_created: 7
  files_modified: 3
---

# Phase 9 Plan 06: Windows Toast Notification Stack Summary

Windows toast notification stack implemented with raw WinRT COM via go-ole, providing per-toast Tag/Group and Action Center cleanup (NOTIF-05) that the jackmordaunt/go-toast/v2 library does not expose natively.

## What Was Built

### Task 1 — Constants + cross-platform unit tests (commit fcbe0f1)
- `src/app/toast.go`: pinned `aumidDev`/`aumidProd` AUMIDs, go-mapi-owned CLSID `{6352C677-78F0-444F-AAA9-724EB43DBCB0}`, `toastGroup`, all UI-SPEC copy constants, `toastErrorCopy()`, `activeAUMID()`
- `src/app/toast_test.go`: `TestToastErrorCopy`, `TestToastActivatorGUID_NotDefault`, `TestAUMIDsDistinct` — all cross-platform, all pass

### Task 2 — Toast stack implementation (commit 24cc28a)
- `src/app/toast_windows.go` (`//go:build windows`): `initToasts`, `emitArrivalToast` (NOTIF-02 privacy-safe payload: display name + subject + attach count), `emitDraftSuccessToast` (D-11 suppressed when window visible+focused), `emitErrorToast` (always fires per D-11), `emitSummaryInvalidGrantToast` (D-10), `clearToastForEmail` (NOTIF-05 — clears arrival + error tags, leaves `:success` for user to dismiss), `displayFrom` (uses `Recipients.To[0]` name/address, falls back to `OriginApp`)
- `src/app/toast_shim_windows.go` (`//go:build windows`): `shimPushWithTagGroup` (re-implements the jackmordaunt push path via raw WinRT, adds Tag+Group via `IToastNotification2.put_Tag/put_Group`), `shimClearToast` (WinRT `IToastNotificationManagerStatics2.GetHistory().Remove(tag, group, aumid)`)
- `src/app/toast_stub.go` (`//go:build !windows`): no-op stubs for cross-platform compile
- `src/app/app.go` changes:
  - `initToasts(a)` call in `startup()` after `bootstrapAuth()` (non-fatal on error)
  - `knownIds` closure-scoped map seeded from initial snapshot; arrival detection in `SetAfterDispatch` fires `emitArrivalToast` for genuinely new IDs only
  - `handleToastAction(args string)` method: URL-query dispatch for `create-draft`, `dismiss`, `open` actions (T-4 allowlist)
  - `CreateDraftForID`: `emitErrorToast` on failure, `emitDraftSuccessToast`+`clearToastForEmail` on success
  - `DismissEmail`: `clearToastForEmail` on success
- `src/app/automode.go` changes:
  - `draftOne` success: `emitDraftSuccessToast`+`clearToastForEmail`
  - `draftOne` failure: `emitErrorToast`
  - `drain`: `emitSummaryInvalidGrantToast` on first `ErrInvalidGrant` per drain (D-10)
- `src/app/go.mod`: promoted both deps from indirect to direct

### Task 3 — PowerShell AUMID scripts (commit d50f0ca)
- `scripts/register-dev-aumid.ps1`: idempotent HKCU Start Menu shortcut with AUMID `com.marcfargas.gomapi.dev` via inline C# (`IShellLinkW` + `IPersistFile` + `IPropertyStore` + `PKEY_AppUserModel_ID`). Supports `-ExePath`, `-Force` flags.
- `scripts/unregister-dev-aumid.ps1`: removes the shortcut (idempotent no-op if absent).

### Task 4 — checkpoint:human-verify (DEFERRED 2026-04-19)

End-to-end QA requires a real Windows dev machine with the AUMID shortcut registered. Checks 1–9 listed in the checkpoint block below.

**Status:** DEFERRED per user decision during Phase 9 execution — same reasoning as Plan 09-05 (Shell_NotifyIcon / toast surfaces are not programmatically inspectable on CI; building a Windows Sandbox + FlaUI harness will replace the recurring manual cost). Tracked by `.planning/todos/pending/2026-04-19-automate-tray-visual-qa-windows-sandbox.md` — the todo scope will extend to cover toast activation + Action Center persistence.

Code is accepted as-written. Manual checks 1–9 below remain the reference matrix until the sandbox automation lands.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `MustQueryInterface` panics in test environment**
- **Found during:** Task 2, first test run after implementing toast calls in `CreateDraftForID`
- **Issue:** `shimClearToast` and `shimPushWithTagGroup` used `MustQueryInterface` (panics on failure) throughout the WinRT shim. In the Go test runner, WinRT COM interfaces are not available (no real notification platform), so QueryInterface returns "Interfaz no compatible" and MustQueryInterface panics with a recovered panic — but this still kills the test.
- **Fix:** Replaced all 5 `MustQueryInterface` calls with `QueryInterface` (returns `(*IUnknown, error)`), propagating errors through the normal Go error path.
- **Files modified:** `src/app/toast_shim_windows.go`
- **Commit:** 24cc28a (included in Task 2 commit)

**2. [Rule 1 - Bug] `displayFrom` referenced non-existent `msg.From` field**
- **Found during:** Task 2, build attempt
- **Issue:** Plan's `toast_windows.go` step referenced `msg.From.Name` and `msg.From.Address`, but `MailMessage` in `internal/mapi/protocol.go` has no `From` field — it models outgoing emails where the sender is the local user. The struct has `Recipients` (To/CC/BCC) and `OriginApp`.
- **Fix:** `displayFrom()` now reads `Recipients.To[0].Name`/`.Address` as the "To: Name" display prefix, falling back to `OriginApp`, then `"go-mapi"`.
- **Files modified:** `src/app/toast_windows.go`
- **Commit:** 24cc28a

## Known Stubs

None. The `toast_stub.go` no-ops are intentional platform stubs (non-Windows), not data-flow stubs.

## Threat Surface Scan

No new network endpoints, auth paths, or schema changes. The toast COM activation callback (`handleToastAction`) is bounded by:
- URL query arg parsing with `url.ParseQuery`
- Strict action allowlist (`create-draft`, `dismiss`, `open` only)
- `validateEmailID` guards before any watcher calls

All within the plan's threat model (T-4 mitigated as designed).

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1 | fcbe0f1 | feat(09-06): pin AUMID+CLSID constants, toast copy helpers, cross-platform unit tests |
| 2 | 24cc28a | feat(09-06): implement Windows toast notification stack |
| 3 | d50f0ca | feat(09-06): add PowerShell scripts for dev AUMID shortcut registration |

## Self-Check: PASSED

Files verified:
- `src/app/toast.go` — FOUND
- `src/app/toast_windows.go` — FOUND
- `src/app/toast_shim_windows.go` — FOUND
- `src/app/toast_stub.go` — FOUND
- `src/app/toast_test.go` — FOUND
- `scripts/register-dev-aumid.ps1` — FOUND
- `scripts/unregister-dev-aumid.ps1` — FOUND

Commits verified: fcbe0f1, 24cc28a, d50f0ca — all present in git log.

Tests: `go test ./src/app/...` — PASS (11 tests, 0 failures).
Build: `go build ./...` — PASS.
