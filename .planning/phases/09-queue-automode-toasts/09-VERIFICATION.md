---
phase: 09-queue-automode-toasts
verified: 2026-04-19T19:00:00Z
status: verified
accepted_by_user: 2026-04-24
acceptance_note: "go-mapi v3 confirmed functional in real-world use; remaining edge cases tracked as pending todos (see acceptance section)."
score: 5/5 must-haves verified
overrides_applied: 0
human_verification:
  - test: "Tray icon visual QA — queue/error/idle states"
    expected: "Icon changes to tray-has-queue.ico when queue non-empty; reverts to idle when empty; error icon takes priority over has-queue per D-16 priority"
    why_human: "computeTrayVisual is unit-tested but the LockOSThread tray goroutine and systray.SetIcon live rendering requires a Windows sandbox with real systray"
  - test: "Toast E2E QA — arrival, draft-success, error, and dismiss (NOTIF-01..05)"
    expected: "Arrival toast fires on new email when window hidden; draft-success toast fires on successful auto-draft when window hidden; error toasts always fire regardless of window state; tag/group-based History.Remove clears toast from Action Center on dismiss/processed (NOTIF-05); toasts do not fire when window visible and focused (D-11)"
    why_human: "Toast rendering requires real AUMID registration, COM WinRT stack, and Action Center — not testable without the real Windows shell environment; register-dev-aumid.ps1 must be run first"
  - test: "Full Phase 9 E2E QA — complete user flows"
    expected: "User can view queued emails in main window (QUEUE-01); Create Draft button drafts email and removes row (QUEUE-02/03); Dismiss removes row (QUEUE-04); Manual/Auto-draft toggle persists across restart (QUEUE-05/06); Pause/Resume halts and resumes auto-draft (QUEUE-07); ReAuth banner visible on invalid_grant; one summary toast on invalid_grant drain halt (D-10); drafted-flash fires in window when visible+focused, toast fires when hidden (D-04/D-11)"
    why_human: "Full wiring from MAPI DLL through watcher → automode → toast → UI requires real Windows install with the DLL registered; cannot be exercised by unit/component tests alone"
---

# Phase 9: queue-automode-toasts Verification Report

**Phase Goal:** Users can view queued emails in the main window, act on them individually, set an automatic draft mode, and receive Windows toast notifications when new emails arrive.
**Verified:** 2026-04-19T19:00:00Z
**Status:** human_needed (5/5 automated checks pass; 3 human QA checkpoints remain)
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | User can view queued emails in the main window | VERIFIED | `QueueRow.svelte` renders sender/subject/attachment-count; `App.svelte:238` iterates queue; `GetQueue` Wails binding at `app.go:420`; watcher bridge emits `queue-changed`; 12-case `QueueRow.test.ts` passes |
| 2 | User can act on individual emails (create draft, dismiss) | VERIFIED | `CreateDraftForID` at `app.go:434`; `DismissEmail` at `app.go:508`; both bound in `wailsjs/go/main/App.d.ts`; `QueueRow.svelte` wires buttons to these bindings with loading/done states |
| 3 | User can toggle between Manual and Auto-draft mode, and the setting persists | VERIFIED | `SetMode`/`GetMode` at `app.go:547,541`; `AppSettings.Mode` in `settings.go:20`; `loadSettings`/`saveSettings` with atomic `windows.MoveFileEx` write; `ModeToggle.svelte` bound via `settings.ts`; `GetSettings`/`SaveSettings` bindings present |
| 4 | Auto-draft mode automatically processes queued emails | VERIFIED | `automode.go:86` drain loop; `automodeWake` 1-slot channel at `watcher_bridge.go:24,70`; 30s safety ticker; `inflight` mutex prevents double-draft (T-3); drain halts on first `invalid_grant` (D-10); `emitSummaryInvalidGrantToast` called at `automode.go:114`; `backlogSkip` set at `app.go:55` with `pruneBacklogSkip` at `app.go:199` |
| 5 | Windows toast notifications fire for email arrivals, draft outcomes, and errors | VERIFIED | `toast.go` CLSID `{6352C677-78F0-444F-AAA9-724EB43DBCB0}`; `aumidOverride` ldflags seam at `toast.go:53`; `toast_shim_windows.go` provides Tag/Group/History.Remove (NOTIF-05); `emitArrivalToast` wired at `app.go:188`; `emitDraftSuccessToast`/`emitErrorToast`/`clearToastForEmail` wired in both `app.go` and `automode.go`; window-visibility guard `isWindowVisibleAndFocused()` at `App.svelte:142` (D-11); `register-dev-aumid.ps1` present |

**Score:** 5/5 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/app/auth.go:759` | `bootstrapAuth() <-chan struct{}` | VERIFIED | Signature confirmed; hermetic userinfo stubs in auth_test.go |
| `src/app/settings.go` | `AppSettings` struct + load/save | VERIFIED | `type AppSettings struct` at line 20; `windows.MoveFileEx` atomic write |
| `src/app/paths.go:39` | `appDataDir() string` | VERIFIED | Returns `%APPDATA%\go-mapi\` |
| `src/app/watcher_bridge.go` | `automodeWake chan struct{}` | VERIFIED | Dual fan-out at line 70; 1-slot non-blocking send |
| `src/app/automode.go` | Full automode loop | VERIFIED | `drain`, `draftOne`, `classifyAutomodeError`, `safeIDPrefix`, `tryAcquire`/`release` inflight map |
| `internal/mapi/watcher.go` | Idempotent `MarkProcessed`/`Delete` | VERIFIED | Both methods have idempotent-guard comments at lines 156 and 191 |
| `src/app/app.go` | 9 Wails bindings | VERIFIED | `CreateDraftForID`, `DismissEmail`, `GetSettings`, `SaveSettings`, `GetMode`, `SetMode`, `PauseWatching`, `ResumeWatching`, `GetPausedState` all present |
| `src/app/frontend/wailsjs/go/main/App.d.ts` | All 9 bindings typed | VERIFIED | All 9 functions exported with correct TypeScript signatures |
| `src/app/frontend/wailsjs/go/models.ts` | `AppSettings` class | VERIFIED | Present with `Mode`, `Paused` fields |
| `src/app/assets/tray/tray-has-queue.ico` | Has-queue tray icon | VERIFIED | 15086 bytes |
| `src/app/tray.go` | `computeTrayVisual`, `trayRefreshCh`, Pause menu | VERIFIED | `computeTrayVisual` at line 41 (pure, testable); `trayRefreshCh` channel; Pause menu item at line 99; LockOSThread-safe refresh loop |
| `src/app/toast.go` | Toast wrappers + CLSID + aumidOverride | VERIFIED | Custom GUID `{6352C677-78F0-444F-AAA9-724EB43DBCB0}`; `aumidOverride` ldflags seam; all 4 emit helpers present |
| `src/app/toast_shim_windows.go` | WinRT History.Remove shim | VERIFIED | `shimClearToast`, `shimPushWithTagGroup`, `ToastNotificationHistory` COM shim; CR-01 (`this` pointer) fixed in commit 5f7f46a |
| `src/app/toast_stub.go` | `//go:build !windows` stub | VERIFIED | No-op stubs for non-Windows builds |
| `scripts/register-dev-aumid.ps1` | Dev AUMID registration script | VERIFIED | Sets `PKEY_AppUserModel_ID` = `com.marcfargas.gomapi.dev` via IPropertyStore |
| `src/app/frontend/src/lib/styles.css` | 6 design tokens | VERIFIED | `--space-xl`, `--space-2xl`, `--space-btn-x`, `--c-error-bg`, `--c-success-flash`, `--c-success-text` at lines 15-20 |
| `src/app/frontend/src/lib/components/ReAuthBanner.svelte` | Uses CSS token (not hardcoded color) | VERIFIED | `var(--c-destructive)` used; no `#d93025` literal |
| `src/app/frontend/src/lib/settings.ts` | `fetchSettings`, `subscribeAutoDraftResult` | VERIFIED | Both present with PRIVACY NOTE |
| `src/app/frontend/src/lib/components/ModeToggle.svelte` | Segmented control with ARIA | VERIFIED | `role="group" aria-label="Draft mode"`, `aria-pressed` on each button |
| `src/app/frontend/src/lib/components/AutoDraftErrorBadge.svelte` | Error badge with `role="status"` | VERIFIED | `role="status"`; "Signed out"/"Network error"/"Gmail error" strings |
| `src/app/frontend/src/lib/components/QueueRow.svelte` | Full queue row with D-02 attachment hide | VERIFIED | `(unknown sender)`, `(no subject)`, `Creating…`, `✓ Drafted`, `Sign in first`, D-02 attachment hiding |
| `src/app/frontend/src/lib/components/QueueRow.test.ts` | 12-case test suite | VERIFIED | Includes `hides attachment count when count === 0 (D-02)` |
| `src/app/frontend/src/lib/components/SignedInHeader.svelte` | Imports and renders `ModeToggle` | VERIFIED | `import ModeToggle` at line 3; `<ModeToggle>` at line 18 |
| `src/app/frontend/src/App.svelte` | Full wiring + D-04/D-11 visibility guard | VERIFIED | `subscribeAutoDraftResult` at line 111; `isWindowVisibleAndFocused()` at line 142 using `document.visibilityState === 'visible' && document.hasFocus()`; `<QueueRow` at line 238 |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `watcher_bridge.go` | `automode.go` | `automodeWake` 1-slot channel | WIRED | Non-blocking `case b.automodeWake <- struct{}{}:` fan-out at line 70 |
| `automode.go` | `gmail.go` | `MakeAuthenticatedGmailCall` → `gc.CreateDraft` | WIRED | `draftOne` at `automode.go:142`; `gmailBaseURLOverride` test seam |
| `automode.go` | `watcher.go` | `MarkProcessed` on success | WIRED | `automode.go:181` |
| `automode.go` | `toast.go` | `emitSummaryInvalidGrantToast`, `emitErrorToast`, `emitDraftSuccessToast`, `clearToastForEmail` | WIRED | All 4 call sites in `automode.go` |
| `app.go` | `toast.go` | `emitArrivalToast` on queue event | WIRED | `app.go:188` in `afterDispatch` |
| `tray.go` | `trayRefreshCh` | `sendTrayRefresh()` helper | WIRED | All state-mutating App methods call `sendTrayRefresh()`; tray loop at `tray.go:128` |
| `App.svelte` | `QueueRow.svelte` | `$derived` queue list render | WIRED | `<QueueRow` at `App.svelte:238` |
| `SignedInHeader.svelte` | `ModeToggle.svelte` | Direct component import | WIRED | Import + render confirmed |
| `ModeToggle.svelte` | `settings.ts` | `fetchSettings`, `SaveSettings` binding | WIRED | Settings module confirmed present with binding calls |
| `App.svelte` | `settings.ts` | `subscribeAutoDraftResult` | WIRED | `App.svelte:111` |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `QueueRow.svelte` | `email` prop | `App.svelte` queue from `GetQueue` Wails binding → `EmailWatcher.Snapshot()` → filesystem | Yes — real JSON files from `%TEMP%\go-mapi\` | FLOWING |
| `ModeToggle.svelte` | `settings` / `mode` | `GetSettings` → `loadSettings` → `settings.json` on disk | Yes — real `AppSettings` struct deserialized from disk | FLOWING |
| `AutoDraftErrorBadge.svelte` | `category` prop | `auto-draft-result` event → `classifyAutomodeError` → real Gmail call error | Yes — live error from Gmail/network | FLOWING |
| `App.svelte` | `queue` state | `EventsOn("queue-changed")` → `GetQueue()` → `watcher.Snapshot()` | Yes — real watcher in-memory state from filesystem | FLOWING |

### Behavioral Spot-Checks

Step 7b: Verified via test suite results (68/68 frontend Vitest tests pass; `go test ./internal/mapi/... ./src/app/...` passes). Full E2E behavioral checks require running Windows desktop — deferred to human verification section.

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| `bootstrapAuth` returns `<-chan struct{}` | Grep `src/app/auth.go` | Line 759: `func (a *App) bootstrapAuth() <-chan struct{}` | PASS |
| `AppSettings` serializes to JSON | Grep `src/app/settings.go` | `type AppSettings struct` with `json:` tags confirmed | PASS |
| `automodeWake` non-blocking send | Grep `src/app/watcher_bridge.go` | `case b.automodeWake <- struct{}{}:` select with default | PASS |
| `classifyAutomodeError` covers 3 categories | Grep `src/app/automode.go` | `signed-out`, `network`, `gmail` — all 3 branches | PASS |
| All 9 Wails bindings typed | Read `wailsjs/go/main/App.d.ts` | All 9 function signatures present | PASS |
| D-11 window-visibility guard | Grep `src/app/frontend/src/App.svelte` | `isWindowVisibleAndFocused()` with `document.visibilityState` | PASS |
| CR-01 fix: COM `this` pointer | Read `toast_shim_windows.go` | `uintptr(unsafe.Pointer(f))` — not `0` | PASS |
| Custom CLSID (not library default) | Grep `src/app/toast.go` | `{6352C677-78F0-444F-AAA9-724EB43DBCB0}` | PASS |

### Requirements Coverage

| Requirement | Source Plans | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| QUEUE-01 | 09-07, 09-08, 09-09 | View queued emails in main window | SATISFIED | `QueueRow.svelte` + `App.svelte` queue render + `GetQueue` binding |
| QUEUE-02 | 09-04, 09-09 | Create draft from queue row | SATISFIED | `CreateDraftForID` binding + QueueRow button wired |
| QUEUE-03 | 09-03, 09-04 | Remove email from queue after draft | SATISFIED | `MarkProcessed` called in `draftOne` + `CreateDraftForID` paths |
| QUEUE-04 | 09-04, 09-09 | Dismiss (delete) email from queue | SATISFIED | `DismissEmail` binding + `watcher.Delete` idempotent |
| QUEUE-05 | 09-02, 09-04 | Manual/Auto-draft toggle in UI | SATISFIED | `ModeToggle.svelte` + `SetMode`/`GetMode` bindings |
| QUEUE-06 | 09-02 | Mode persists across restart | SATISFIED | `AppSettings.Mode` → `settings.json` via atomic write; loaded in `startup()` |
| QUEUE-07 | 09-04 | Pause/Resume watching | SATISFIED | `PauseWatching`/`ResumeWatching`/`GetPausedState` bindings; Pause menu in tray |
| NOTIF-01 | 09-06 | Toast on new email arrival | SATISFIED | `emitArrivalToast` at `app.go:188`; window-visibility guard (D-11) |
| NOTIF-02 | 09-06 | Toast on successful draft | SATISFIED | `emitDraftSuccessToast` in `app.go:491` and `automode.go:189`; D-11 guard |
| NOTIF-03 | 09-06 | Toast on draft error | SATISFIED | `emitErrorToast` in `app.go:482` and `automode.go:177`; always fires (D-11) |
| NOTIF-04 | 09-06 | Toast on invalid_grant drain halt | SATISFIED | `emitSummaryInvalidGrantToast` at `automode.go:114` (D-10 one-shot) |
| NOTIF-05 | 09-06 | Clear toast from Action Center on dismiss/process | SATISFIED | `clearToastForEmail` → `shimClearToast` → `ToastNotificationHistory.Remove`; called in both dismiss and draft-success paths |
| SHELL-02 | 09-05 | Tray icon reflects queue/error/idle state | SATISFIED | `computeTrayVisual` pure function + D-16 priority; `trayRefreshCh` routes updates safely |
| SHELL-07 | 09-05 | Pause/Resume accessible from tray | SATISFIED | Pause menu item at `tray.go:99`; `isPaused` gate in `drain()` |
| QUAL-03 | 09-01, 09-03 | No sensitive data logged | SATISFIED | `safeIDPrefix` (8-char only); no body/subject/recipient in logs; PRIVACY NOTE in `settings.ts` |
| QUAL-04 | 09-01 | Go test -race passes (CI gate) | SATISFIED | WR-01/02/03 fixed; deterministic `bootstrapAuth`; `t.Parallel()` removed from mutating test; race-free `automodeWake` 1-slot channel design |

### Anti-Patterns Found

Anti-pattern scan on all Phase 9 modified files:

| File | Pattern | Severity | Impact |
|------|---------|----------|--------|
| `src/app/automode.go` | None | — | — |
| `src/app/settings.go` | None | — | — |
| `src/app/toast.go` | None | — | — |
| `src/app/toast_shim_windows.go` | None (CR-01 fixed) | — | — |
| `src/app/tray.go` | None | — | — |
| `src/app/app.go` | None | — | — |
| `src/app/watcher_bridge.go` | `_ = os.WriteFile(...)` with comment (WR-05 fix) | Info | Intentional best-effort ignore; documented |
| `src/app/frontend/src/lib/components/QueueRow.svelte` | None | — | — |
| `src/app/frontend/src/App.svelte` | None | — | — |

No blocker or warning anti-patterns. The `_ = os.WriteFile(...)` in `watcher.go` is explicitly intentional per WR-05 fix.

Note: `svelte-check` reports 2 expected `tabindex` a11y warnings on non-interactive elements — these are per UI-SPEC accessibility contract, not defects.

### Human Verification Required

#### 1. Tray Icon Visual QA

**Test:** Run the app with queue items and confirm the tray icon changes:
1. Start `go-mapi.exe` with no queued emails → verify idle tray icon
2. Drop a valid email JSON into `%TEMP%\go-mapi\` → verify tray changes to `tray-has-queue.ico`
3. Dismiss the email → verify tray reverts to idle
4. Trigger an error state → verify error icon takes priority over has-queue (D-16)
5. Confirm tooltip format matches `go-mapi — Manual — N pending` (D-17)

**Expected:** Icon transitions match D-16 priority (error > has-queue > idle); tooltip format correct.

**Why human:** `computeTrayVisual` is unit-tested but `systray.SetIcon` and the LockOSThread tray goroutine require a real Windows systray environment. Cannot be exercised without a running desktop session.

#### 2. Toast E2E QA (NOTIF-01..05)

**Test:** Run `scripts/register-dev-aumid.ps1` first, then:
1. With window hidden, drop email JSON → verify arrival toast fires in Action Center
2. With window visible + focused, drop email JSON → verify NO arrival toast (D-11)
3. In Auto-draft mode, new email → successful draft → verify draft-success toast appears when window hidden
4. In Auto-draft mode, simulate network error → verify error toast fires regardless of window state
5. Dismiss email in UI → verify toast removed from Action Center (NOTIF-05 Tag/Group History.Remove)
6. Sign out mid-drain → verify ONE summary toast (not per-email) (D-10)

**Expected:** Toasts fire per D-11 (arrival/success suppressed when visible+focused; errors always fire); Action Center cleared on dismiss/process per NOTIF-05.

**Why human:** Toast rendering requires real AUMID registration, COM WinRT stack, and Windows Action Center. Not testable via unit or component tests.

#### 3. Full Phase 9 E2E User Flow QA

**Test:** End-to-end flow from MAPI trigger to Gmail draft:
1. Configure a Windows app to use MAPI and send a test email
2. Verify email appears in go-mapi queue within 1s
3. Click "Create Draft" → verify draft in Gmail Drafts; row removed from queue
4. Drop 3 emails, switch to Auto-draft mode → verify all 3 drafted automatically
5. Switch mode back to Manual → drop another email → verify it stays in queue
6. Pause watching → drop email → verify it does NOT appear in queue
7. Resume watching → verify email now appears
8. In Auto-draft mode, when window visible+focused: verify drafted-flash animation fires (D-04) and NO toast fires; when window hidden: verify toast fires and NO flash

**Expected:** All QUEUE-01..07 and D-04/D-11 behaviors work end-to-end with real MAPI DLL and Gmail API.

**Why human:** Full wiring from C++ DLL through watcher → automode → Gmail → toast → UI requires real Windows install with DLL registered; cannot be exercised by unit/component tests.

**Reference:** `.planning/todos/pending/2026-04-19-automate-tray-visual-qa-windows-sandbox.md` — decision to accept human QA for tray/toast visual checks in Phase 9, with a plan to automate in a future phase.

### Code Review Status

All Phase 9 code review findings resolved before verification:

- **CR-01** (toast `this` pointer): Fixed in commit 5f7f46a
- **WR-01** (hardcoded AUMID): Fixed in commit 269fc25 — `aumidOverride` ldflags seam
- **WR-02** (knownIds snapshot race): Fixed in commit e7daf14 — synchronous `watcher.Start()`
- **WR-03** (misleading contract comment): Fixed in commit 931faff — expanded doc-comments
- **WR-04** (dismiss asymmetry undocumented): Fixed in commit 19295d5 — inline comments
- **WR-05** (WriteFile error ignored): Fixed in commit 27dfcbe — `_ =` with explanatory comment
- **IN-01..04**: Intentionally skipped per code review scope (informational only)

### Gaps Summary

No gaps. All 5 success criteria pass automated checks. All 16 requirement IDs (QUEUE-01..07, NOTIF-01..05, SHELL-02, SHELL-07, QUAL-03, QUAL-04) are satisfied by verifiable code artifacts. All code review findings were closed before verification. Three human QA checkpoints remain for tray visual behavior, toast rendering, and full E2E user flows — these are inherent Windows shell behaviors that cannot be exercised programmatically without a live desktop session.

### User Acceptance

**Accepted:** 2026-04-24 by Marc Fargas.

go-mapi v3 is functional in real-world daily use. The three human QA checkpoints (tray visual QA, toast E2E, full Phase 9 E2E user flow) have been confirmed implicitly through the application running in production on author and user machines — queue rendering, Create Draft / Dismiss, Manual/Auto-draft toggle persistence, Pause/Resume, ReAuth banner, arrival toasts, and tray state transitions all work as specified.

Remaining edge cases are tracked as pending todos rather than verification gaps:

- `2026-04-19-automate-tray-visual-qa-windows-sandbox.md` — automate tray visual QA in a future phase.

Closing this verification as `verified` per user acceptance.

---

_Verified: 2026-04-19T19:00:00Z_
_User-accepted: 2026-04-24_
_Verifier: Claude (gsd-verifier)_
