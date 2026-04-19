---
phase: 09-queue-automode-toasts
fixed_at: 2026-04-19T18:15:00Z
review_path: .planning/phases/09-queue-automode-toasts/09-REVIEW.md
iteration: 1
findings_in_scope: 6
fixed: 6
skipped: 0
status: all_fixed
---

# Phase 9: Code Review Fix Report

**Fixed at:** 2026-04-19T18:15:00Z
**Source review:** .planning/phases/09-queue-automode-toasts/09-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 6 (CR-01 + WR-01..05; IN-01..04 skipped per scope)
- Fixed: 6
- Skipped: 0

All fixes verified with `go test ./internal/mapi/... ./src/app/...` (2 packages, all pass) and `npm run test:run` (11 test files, 68 tests, all pass).

## Fixed Issues

### CR-01: CreateToastNotificationFromDoc passes wrong this pointer

**Files modified:** `src/app/toast_shim_windows.go`
**Commit:** 5f7f46a
**Applied fix:** In `createToastNotificationFromDoc`, replaced the zero `uintptr` passed as the first syscall argument with `uintptr(unsafe.Pointer(f))` — the actual `IToastNotificationFactory` instance pointer. `IToastNotificationFactory.CreateToastNotification` is an instance method and requires `this` to be the factory COM pointer, not zero. The static-factory pattern (`0` as `this`) is only correct for WinRT activation factory statics such as `GetDefault` at line 451, which remains unchanged.

### WR-01: activeAUMID hardcoded to aumidDev

**Files modified:** `src/app/toast.go`
**Commit:** 269fc25
**Applied fix:** Added a package-level `var aumidOverride string` that can be injected at link time via `-ldflags "-X 'main.aumidOverride=com.marcfargas.gomapi'"`. Updated `activeAUMID()` to return `aumidOverride` when non-empty, falling back to `aumidDev` for dev/test runs without the flag. This exactly mirrors the `oauthClientID`/`oauthClientSecret` pattern in `auth_credentials.go`. Phase 10 will wire `-X main.aumidOverride=$(aumidProd)` in its release build flags.

### WR-02: knownIds snapshot taken before watcher.Start() completes

**Files modified:** `src/app/app.go`
**Commit:** e7daf14
**Applied fix:** Removed the goroutine wrapper around `a.watcher.Start()`. The call is now synchronous in `startup()`, so `processExistingFiles()` fully completes before control returns to the code that seeds `knownIds` via `a.watcher.Snapshot()`. The `watchLoop` goroutine is still spawned inside `Start()` itself, so the only blocking work is the initial directory scan — which is fast and safe to run on the startup goroutine. The error handling path (log + SetTrayError + EventsEmit) is preserved verbatim.

### WR-03: MakeAuthenticatedGmailCall contract comment misleading

**Files modified:** `src/app/auth.go`
**Commit:** 931faff
**Applied fix:** Expanded the doc-comments on `GmailCall` and `MakeAuthenticatedGmailCall` to explicitly state that `statusCode` is only inspected for `401`, that any `(non-401, non-nil err)` is returned directly without retry, and that `(non-401, nil)` is always treated as success. Also documented the `(0, someErr)` transport-error case. No behavior change — comment only.

### WR-04: handleToastAction dismiss case silent on error, asymmetry undocumented

**Files modified:** `src/app/app.go`
**Commit:** 19295d5
**Applied fix:** Added inline comments to the `"dismiss"` switch case explaining that the asymmetry with `"create-draft"` (which calls `showWindow`) is intentional per NOTIF-05 — dismiss is a silent background action. The existing `logError` call for `DismissEmail` failures was retained; added a follow-up comment noting `showWindow` is deliberately absent on dismiss failure, making the design decision explicit for future readers.

### WR-05: os.WriteFile return ignored in moveToErrors

**Files modified:** `internal/mapi/watcher.go`
**Commit:** 27dfcbe
**Applied fix:** Changed the bare `os.WriteFile(...)` call to `_ = os.WriteFile(...)` with an explanatory comment that the ignore is intentional (best-effort sidecar write). This prevents `go vet`/`errcheck` linter warnings if a linter is added in a future phase, and makes the intent explicit to readers.

---

_Fixed: 2026-04-19T18:15:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
