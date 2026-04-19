---
phase: 09-queue-automode-toasts
reviewed: 2026-04-19T00:00:00Z
depth: standard
files_reviewed: 38
files_reviewed_list:
  - internal/mapi/watcher.go
  - internal/mapi/watcher_test.go
  - scripts/register-dev-aumid.ps1
  - scripts/unregister-dev-aumid.ps1
  - src/app/app.go
  - src/app/app_bindings_test.go
  - src/app/auth.go
  - src/app/auth_test.go
  - src/app/automode.go
  - src/app/automode_test.go
  - src/app/frontend/src/App.svelte
  - src/app/frontend/src/App.test.ts
  - src/app/frontend/src/lib/components/AutoDraftErrorBadge.svelte
  - src/app/frontend/src/lib/components/AutoDraftErrorBadge.test.ts
  - src/app/frontend/src/lib/components/ModeToggle.svelte
  - src/app/frontend/src/lib/components/ModeToggle.test.ts
  - src/app/frontend/src/lib/components/QueueRow.svelte
  - src/app/frontend/src/lib/components/QueueRow.test.ts
  - src/app/frontend/src/lib/components/ReAuthBanner.svelte
  - src/app/frontend/src/lib/components/SignedInHeader.svelte
  - src/app/frontend/src/lib/components/SignedInHeader.test.ts
  - src/app/frontend/src/lib/settings.test.ts
  - src/app/frontend/src/lib/settings.ts
  - src/app/frontend/src/lib/styles.css
  - src/app/go.mod
  - src/app/paths.go
  - src/app/paths_test.go
  - src/app/settings.go
  - src/app/settings_test.go
  - src/app/toast.go
  - src/app/toast_shim_windows.go
  - src/app/toast_stub.go
  - src/app/toast_test.go
  - src/app/toast_windows.go
  - src/app/tray.go
  - src/app/tray_test.go
  - src/app/watcher_bridge.go
  - src/app/watcher_bridge_test.go
findings:
  critical: 1
  warning: 5
  info: 4
  total: 10
status: issues_found
---

# Phase 9: Code Review Report

**Reviewed:** 2026-04-19T00:00:00Z
**Depth:** standard
**Files Reviewed:** 38
**Status:** issues_found

## Summary

Phase 9 lands the queue view, auto-draft mode, Windows toast notifications, mode-toggle persistence, and tray refresh wiring. The scope is large and the implementation is well-structured. Privacy discipline (QUAL-03) is consistently observed across the toast, automode, and logging paths — subject/body/recipient content never reaches logs or system APIs. The idempotency contract on `MarkProcessed`/`Delete` is correct and well-tested. The COM/WinRT VTable code in `toast_shim_windows.go` is the highest-risk area and one hard bug was found there (`createToastNotificationFromDoc` passes `0` as the `this` pointer for a non-static COM factory method). Goroutine and channel lifecycle is sound, and the atomic settings write path via `windows.MoveFileEx` is correctly implemented.

---

## Critical Issues

### CR-01: `CreateToastNotificationFromDoc` passes wrong `this` pointer — notification is never created

**File:** `src/app/toast_shim_windows.go:344`

**Issue:** `createToastNotificationFromDoc` constructs a `notifFactory` from the raw `factory *ole.IUnknown` pointer, then calls `vtbl.CreateToastNotification` with `0` (the zero `uintptr`) as the first argument (`this`). COM vtable methods require the object pointer as the first argument in every call. Passing `0` will either crash with an access violation or, on guarded memory, silently succeed but write a null pointer into `outPtr`, causing the subsequent `notification.Release()` to dereference nil and crash.

The root cause is that `CreateToastNotification` is listed as a method on `IToastNotificationFactory`, which is **not** a static factory — it requires an instance pointer. The pattern used for the static `GetDefault` call (line 449–452, which correctly passes `0`) must not be reused here.

```go
// WRONG (current, line 344-351):
hr, _, _ := syscall.SyscallN(
    vtbl.CreateToastNotification,
    0,                                // ← WRONG: 0 is only correct for static WinRT methods
    uintptr(unsafe.Pointer(doc)),
    uintptr(unsafe.Pointer(&outPtr)),
)

// CORRECT — pass the factory interface pointer as `this`:
f := (*notifFactory)(unsafe.Pointer(factory))
vtbl := (*notifFactoryVtbl)(unsafe.Pointer(f.RawVTable))
hr, _, _ := syscall.SyscallN(
    vtbl.CreateToastNotification,
    uintptr(unsafe.Pointer(f)),       // ← this: the IToastNotificationFactory pointer
    uintptr(unsafe.Pointer(doc)),     // in: IXmlDocument
    uintptr(unsafe.Pointer(&outPtr)), // out: IToastNotification
)
```

Note: `GetDefault` at line 449 legitimately passes `0` because `IToastNotificationManagerStatics5.GetDefault` is documented as a **static** (no `this`) WinRT activation factory method. `CreateToastNotification` on `IToastNotificationFactory` is an **instance** method; it needs `f` as `this`.

---

## Warnings

### WR-01: `activeAUMID()` is hardcoded to `aumidDev` — prod builds will ship with the dev AUMID

**File:** `src/app/toast.go:48-50`

**Issue:** `activeAUMID()` unconditionally returns `aumidDev`. The comment says "Phase 10 installer will pass the prod AUMID via a build-time flag or ldflags," but there is no guard, build tag, or ldflags variable to switch this in a release build. If a release binary is produced before Phase 10 lands the injection, production users will get the dev AUMID (`com.marcfargas.gomapi.dev`) permanently registered in Windows Action Center under the wrong app identity.

```go
// Safer: inject via ldflags, fall back to dev only when empty.
var buildAUMID string // injected: -ldflags "-X main.buildAUMID=com.marcfargas.gomapi"

func activeAUMID() string {
    if buildAUMID != "" {
        return buildAUMID
    }
    return aumidDev // dev/test only
}
```

Until Phase 10 wires this, the function should at minimum log a warning when returning `aumidDev` from a non-dev binary, or be backed by an ldflag stub identical to the existing `oauthClientID` pattern.

---

### WR-02: `startup` race — `knownIds` snapshot taken before `watcher.Start()` completes

**File:** `src/app/app.go:167-201`

**Issue:** At line 120-127, `watcher.Start()` is launched in a goroutine (fire-and-forget). At line 167, `a.watcher.Snapshot()` is called to seed `knownIds`. If `Start()` has not yet called `processExistingFiles()`, the seed snapshot is empty, and all pre-existing emails will later generate spurious arrival toasts (NOTIF-04 violation). The existing comment acknowledges this as "seeds to the current queue at startup to prevent stale emails from triggering arrival toasts," but the goroutine boundary means the seed is racy.

```go
// FIX: start watcher synchronously (at least processExistingFiles),
// or move the knownIds seed into a post-Start callback.
// Simplest: move watcher.Start() outside the goroutine and make
// startup resilient to a blocking Start call (Start is already fast;
// it only adds the fsnotify watch and reads existing files).
if startErr := a.watcher.Start(); startErr != nil {
    logError("watcher start: %v", startErr)
    a.SetTrayError("watcher start failed")
    wruntime.EventsEmit(a.ctx, "queue-error", startErr.Error())
}
// Now seed knownIds with a guaranteed post-processExistingFiles snapshot:
initialSnap := a.watcher.Snapshot()
```

---

### WR-03: `MakeAuthenticatedGmailCall` returns `nil` when `fn` returns `(non-401, non-nil error)`

**File:** `src/app/auth.go:656-661`

**Issue:** Lines 656-661 read:

```go
status, err := fn(token)
if err == nil && status != 401 {
    return nil
}
if status != 401 {
    return err
}
```

When `fn` returns `(500, someErr)`, the first condition is false (`err != nil`), so execution falls through to the second condition. `status != 401` is true (it is 500), so `return err` fires — correct. However, when `fn` returns `(0, someErr)` (status zero — which some callers may produce on transport errors before any HTTP status is known), the logic also returns `err` correctly. The tricky edge is when `fn` returns `(401, nil)` (status 401 with no error value): the intent is to trigger the retry path. The code reaches the second `if status != 401` which is false, so it falls through to the retry block — also correct.

The actual bug: when `fn` returns `(200, someErr)` — status 200 with a non-nil error — the first condition `err == nil && status != 401` is false (err is non-nil), and the second `status != 401` is true, so `err` is returned. This is technically correct behavior (caller returned an inconsistent state), but the combination `(non-401 status, nil error)` at lines 656-658 short-circuits with `return nil` **without inspecting status**. This means `fn` can return `(200, nil)` or `(0, nil)` or `(500, nil)` and the call is treated as success. Only a `401` status with a non-nil error (or nil error) matters for the retry path. This is a design ambiguity rather than a crash path, but it means the contract "return statusCode int" from `GmailCall` is only meaningful for `401` — callers who return `(500, nil)` or `(0, nil)` silently succeed. The `draftOne` and `CreateDraftForID` callers always pair a non-nil error with any non-200 status, so the current code is safe in practice. Consider documenting that the status code is **only** inspected for `401`.

**Fix:** Add a comment to `GmailCall` and `MakeAuthenticatedGmailCall` clarifying that a non-nil `err` paired with any status other than `401` is always bubbled directly (no retry). The current behavior is correct; the documentation is misleading.

---

### WR-04: `handleToastAction` for `"dismiss"` does not call `showWindow` — UX inconsistency

**File:** `src/app/app.go:580-586`

**Issue:** When a toast's "Dismiss" action button is tapped, `handleToastAction` calls `DismissEmail(id)` but does **not** call `showWindow()`. The "Create draft" action and the "open" (default) action both call `showWindow()`. Per NOTIF-05, the intent is to clear the toast and delete the file silently — the app need not surface. However, if the dismiss fails (file already gone), the error is logged but no user feedback is given and the window remains hidden. This is probably intentional (dismiss is silent), but the asymmetry between the dismiss and create-draft paths on error should be documented. Currently, failed dismiss errors are silently swallowed with only a log line.

**Fix:** Document the asymmetry explicitly in the switch comment, or surface a visible cue on failure:

```go
case "dismiss":
    if err := a.DismissEmail(id); err != nil {
        logError("toast: DismissEmail %s: %v", safeIDPrefix(id), err)
        // Intentionally not calling showWindow on dismiss failure —
        // the row will be visible if the user opens the app, and the
        // error is not actionable from the notification.
    }
    // No showWindow: dismiss is a silent background action (NOTIF-05).
```

---

### WR-05: `watcher.go` — `os.WriteFile` in `moveToErrors` ignores the error return

**File:** `internal/mapi/watcher.go:364`

**Issue:** `moveToErrors` calls `os.WriteFile(logFile, []byte(reason), 0644)` without capturing or logging the error. This is a minor robustness issue — if the error directory is read-only or the disk is full, the `.error` sidecar is silently lost. Since `internal/mapi` has no logging infrastructure, the options are limited, but at least returning the combined error to the caller or using a named sentinel would make the failure visible.

```go
// Current:
os.WriteFile(logFile, []byte(reason), 0644)

// Better: ignore intentionally but make it explicit:
_ = os.WriteFile(logFile, []byte(reason), 0644)
```

The bare `os.WriteFile` call without `_` will generate a `go vet` or `errcheck` linter warning. Making the ignore explicit prevents CI friction if a linter is added in a future phase.

---

## Info

### IN-01: `toast_shim_windows.go` — `iToastNotificationManagerStatics2.GetHistory` vtable offset may be wrong

**File:** `src/app/toast_shim_windows.go:43, 175-187`

**Issue:** `iToastNotificationManagerStatics2Vtbl` lists only `GetHistory` as the single method after `IInspectableVtbl`. The actual `IToastNotificationManagerStatics2` interface (Windows.UI.Notifications.IToastNotificationManagerStatics2, IID `{7AB93C52-0E48-4750-BA9D-1A4113981847}`) has the following method order after the 6 `IInspectable` slots: `CreateToastNotifierForUser`, `GetHistory`. The `GetHistory` method is at vtable index **7** (0-indexed after the 6 IInspectable slots), not index 6. If `CreateToastNotifierForUser` is missing from the vtable struct, `GetHistory` will land on the wrong slot and call the wrong function.

This is lower-severity than CR-01 because the `shimClearToast` path is exercised only on `MarkProcessed`/`Delete`, not in the happy notification path, and an HRESULT failure on the wrong method is caught and logged. Verify the vtable order against the Windows SDK header before shipping.

**Fix:** Add `CreateToastNotifierForUser` as a placeholder before `GetHistory`:

```go
type iToastNotificationManagerStatics2Vtbl struct {
    ole.IInspectableVtbl
    CreateToastNotifierForUser uintptr // vtable slot 6
    GetHistory                 uintptr // vtable slot 7
}
```

---

### IN-02: `App.svelte` — `handleDismiss` silently swallows all errors

**File:** `src/app/frontend/src/App.svelte:170`

**Issue:** `handleDismiss` catches all errors and does nothing:

```ts
async function handleDismiss(id: string) {
    try { await DismissEmail(id); } catch { /* ignore dismiss errors */ }
}
```

If `DismissEmail` fails (e.g., watcher not ready), the row stays in the queue with no visual feedback. The automode path emits an `auto-draft-result` error event on failure; the dismiss path has no equivalent. Per the current design this is intentional (dismiss errors are rare and idempotent), but a future file-permission failure (e.g., antivirus locking) would be invisible.

**Suggestion:** Log or count dismiss errors locally without surfacing to the user — at minimum, keep a console log behind a debug flag so integration-test sessions can surface failures.

---

### IN-03: `toast.go` — `activeAUMID()` is not covered by a build-tag gate for `aumidProd`

**File:** `src/app/toast.go:48-50`

**Issue:** `aumidProd` is declared and documented but never used in production code paths. `go vet` and `go build` will not flag an unused `const`, but `aumidProd` exists solely as documentation that the prod value will eventually be needed. A comment referencing "Phase 10" is the only indicator. This is fine for now, but the constant will be unreferenced until Phase 10 wires the ldflags injection. A `//nolint:deadcode` or a blank assignment `_ = aumidProd` is not needed (it is a const), but the Phase 10 dependency should be tracked in the TODO/PLAN to avoid shipping the dev AUMID silently.

**Suggestion:** No code change needed; ensure the Phase 10 plan explicitly gates on wiring `activeAUMID` to an ldflags variable before release.

---

### IN-04: `styles.css` — `.queue-row` grid column definition duplicated between CSS file and component

**File:** `src/app/frontend/src/lib/styles.css:29` and `src/app/frontend/src/lib/components/QueueRow.svelte:96`

**Issue:** The global `styles.css` defines `.queue-row` with `grid-template-columns: minmax(100px, 1fr) minmax(100px, 2fr) auto`, while `QueueRow.svelte`'s scoped `<style>` redefines `.queue-row` with `grid-template-columns: 1fr 2fr auto auto` (four columns). The component's scoped style wins due to Svelte's specificity rules, but the global definition is dead code that could cause confusion when reading the stylesheet. The global `.queue-row:hover` rule also conflicts with the component's scoped variant.

**Suggestion:** Remove the `.queue-row`, `.queue-row:hover`, `.queue-row:focus-visible`, `.queue-row .sender`, `.queue-row .subject`, and `.queue-row .meta` rules from `styles.css` — they are all superseded by the component's scoped styles.

---

_Reviewed: 2026-04-19T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
