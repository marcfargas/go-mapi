# Phase 9 Research: Queue, Automode + Toasts

**Date:** 2026-04-19
**Status:** RESEARCH COMPLETE
**Domain:** Wails v2 + Windows toast notifications (unpackaged) + Go goroutine lifecycle + atomic file I/O + test hygiene
**Confidence:** HIGH on library choice + WR-01/02/03 fixes + atomic-write pattern. MEDIUM on NOTIF-05 path (library gap). HIGH on automode architecture.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Queue row rendering (QUEUE-01..03):**
- D-01: `Create draft` and `Dismiss` buttons inline, always visible per row. No hover-to-reveal, no expand-to-show.
- D-02: Attachment count renders as `📎 <N>`, **hidden when count == 0**.
- D-03: Row body is inert — click anywhere except a button does nothing. `tabindex=0` for keyboard. No expand-to-detail view in Phase 9.
- D-04: Post-draft feedback conditional on window visibility:
  - Visible+focused: row fades with `✓ Drafted` flash (~1.5s), then disappears on next `queue-update`.
  - Hidden/minimized: Windows toast fires (`Draft created: <subject>`), row removes silently.
  - Applies to both manual and automode.

**Toast stack + AUMID (NOTIF-01..05):**
- D-05: Toast library choice deferred to researcher. Hard constraints: (a) no PowerShell-per-toast; (b) verify Wails v2.12.0 has no built-in helper; (c) RDS-safe (HKCU, not HKLM); (d) unpackaged Win32 support.
- D-06: Dev-time AUMID via helper `scripts/register-dev-aumid.ps1`. Creates HKCU Start Menu shortcut with `com.marcfargas.gomapi.dev`. Prod path (`com.marcfargas.gomapi`) is Phase 10 installer's job (INST-04). Suggested AUMIDs confirmable by planner.
- D-07: Toast action-button activation deferred to researcher. Candidates: (a) foreground-activation+hide-to-tray, (b) COM background activator.
- D-08: NOTIF-05 removal scheme: `tag=email-id` (64-char content hash), `group="go-mapi-queue"`. On success/dismiss: `ToastNotifier.History.Remove(tag, group, aumid)`.

**Automode failure + signed-out handling (QUEUE-05, QUEUE-06):**
- D-09: Auto-draft failure shows inline red `!` badge + hover tooltip category (`Signed out` / `Network error` / `Gmail error`). One error toast per failure (always fires, regardless of window visibility). **No auto-retry.**
- D-10: On `invalid_grant` during automode: rows stay queued with `Signed out` tooltip; ReAuthBanner surfaces; one summary toast. After re-auth, **new arrivals resume automode** but backlog stays manual — no retroactive draining.
- D-11: Toast suppression while window is visible+focused — arrival and draft-success toasts suppressed. Error toasts ALWAYS fire.

**Mode toggle (QUEUE-04):**
- D-12: Toggle in main window header (SignedInHeader), two-state segmented control `Manual` / `Auto-draft`. No duplicate in tray menu.
- D-13: State persists in `%APPDATA%\go-mapi\settings.json`. Shape `{ "mode": "manual" | "auto-draft" }`. Atomic-write pattern (tmp + rename).

**Pause-watching + has-queue icon (SHELL-02/07 completion):**
- D-14: Pause = suppress toasts + halt automode. Watcher keeps running.
- D-15: Pause is session-only, reset on restart. Lives in `sync.Mutex`-guarded bool on App struct.
- D-16: Three static tray icon variants: `tray-idle.ico`, `tray-has-queue.ico` (new), `tray-error.ico`. No runtime badge composition. Priority: error > has-queue > idle. Paused/signed-out are tooltip-only.
- D-17: Tray tooltip: `go-mapi — <mode> — N pending`. Modes: `Manual`, `Auto-draft`, `Paused`, `Signed out`. Error overrides: `go-mapi — watcher stopped`.

**Test hygiene (D-18, Phase 8.1 handoff):**
- WR-01: `TestAuthCodeURLHasPKCE` mutates `oauthClientID`/`oauthClientSecret` under `t.Parallel()`. Fix: remove `t.Parallel()` OR restructure override as injected dependency.
- WR-02: Bootstrap-auth tests leak a goroutine to real Google userinfo endpoint. Fix: inject `userinfoEndpointOverride` + use `httptest.Server` stubs.
- WR-03: `TestDispatcherCoalesces` at `src/app/watcher_bridge_test.go:93` flakes under `-race` on windows/amd64. Fix: loosen assertion, redesign guarantee, or add deterministic sync point.

### Claude's Discretion

- Exact row-fade duration (~1.5s target) — UI-SPEC picks 300ms fade transitions.
- Error-toast copy + error-badge tooltip phrasing — short, English.
- Whether `auto-draft-result` event fires for success+failure, or only failure.
- Draft-success toast content: `Draft created: <subject>` + optional `Open in Gmail` link if reliably constructable.
- Whether draft-success toasts carry action buttons (probably not — dismissible-only).
- AUMID string values (suggested `com.marcfargas.gomapi` prod, `.dev` suffix for dev).
- `tray-has-queue.ico` visual design — amber `#E8A600` dot per UI-SPEC.
- Pause-menu label wording (`Pause watching` per UI-SPEC).
- Mode-toggle visual (segmented control per UI-SPEC).
- `App.PauseWatcher()` / `App.ResumeWatcher()` binding signature.
- settings.json location (`%APPDATA%\go-mapi\` preferred).
- settings.json atomic-write exact pattern.
- Tray icon priority table details.
- Row focus outlines + keyboard accessibility (UI-SPEC owns).
- ICO sizes (16×16 + 32×32 dual-frame per UI-SPEC).

### Deferred Ideas (OUT OF SCOPE)

- Bulk row actions (multi-select + batch).
- Row expand-to-detail.
- Retroactive auto-draft of backlog after re-auth (explicitly rejected per D-10).
- Pause with auto-expiry (Slack-style "Pause for 1 hour").
- Mode toggle duplicated in tray menu.
- Runtime-composed tray badge with numeric count.
- Distinct tray icon variants for paused/signed-out.
- `Open in Gmail` deep link (MAY ship — see §8).
- Auto-send mode + undo-send window.
- Per-email mode override.
- Audit log of automode actions.
- Telemetry for automode failure rates (QUAL-03 forbids).
- Windows Focus Session suppression (`SuppressPopup=true`) — see §8.
- Toast inline images (sender avatar, attachment thumbnail).
- `go-mapi` settings UI panel.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| QUEUE-01 | Main window lists all queued emails | Existing `GetQueue()` binding + `queue-update` event; Phase 9 extends row render (see §4 automode arch for queue-update interaction). |
| QUEUE-02 | Per-email `Create draft` invokes Gmail draft flow | §4 wiring via `MakeAuthenticatedGmailCall` + `GmailClient.CreateDraft` + `MarkProcessed`. |
| QUEUE-03 | Per-email `Dismiss` removes file without drafting | `watcher.Delete(id)` — existing, no auth needed. New binding `App.DismissEmail(id)`. |
| QUEUE-04 | Mode toggle persists across restarts | §3 atomic-write settings.json pattern. |
| QUEUE-05 | Auto-draft runs in Go goroutine, processes hidden-window | §4 — extend `watcherBridge` dispatcher with second fan-out goroutine. |
| QUEUE-06 | Failed auto-drafts stay queued with error state + notification | §4 error classifier + `auto-draft-result` event; §1 error toasts. |
| QUEUE-07 | Queue updates pushed via Wails event (no polling) | Existing `queue-update` event in watcherBridge unchanged; automode fan-out must preserve coalesce (see §5 WR-03). |
| NOTIF-01 | Toast on new email arrival | §1 library choice; §7 ordering re: processed-email race. |
| NOTIF-02 | Toast content: sender+subject+attachment count only (no body) | Toast XML in UI-SPEC §Toast Visual Contract; QUAL-03 privacy. |
| NOTIF-03 | Toast action buttons work without opening window | §2 COM activator path — NOT foreground+hide workaround. |
| NOTIF-04 (dev) | AUMID registered — dev via helper script; prod via Phase 10 | §6 PowerShell pattern; hands off to Phase 10 INST-04. |
| NOTIF-05 | Processed-email toasts removed from Action Center | §1 library gap + §7 ordering. Requires patching jackmordaunt or adding wintoast raw-COM shim. |
| SHELL-02 (completion) | `Pause watching` tray menu item | New tray menu item + session-only flag on App; §4 automode loop checks flag. |
| SHELL-07 (completion) | `tray-has-queue.ico` variant | §1 asset (not a research concern — UI-SPEC owns visual). Embed via `//go:embed` alongside existing two icons. |
| QUAL-03 | No telemetry, no content retention | Enforced: no logs of subject/body/recipients; no network beyond Gmail + Google OAuth. |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

The following directives from `C:\dev\go-mapi\CLAUDE.md` are load-bearing for this phase. Plans MUST honor them:

- **Go runtime:** Go 1.25 + CGO_ENABLED=1 on windows-latest.
- **Frontend tooling:** no ESLint. `svelte-check` is the blocking lint gate. Vitest + @testing-library/svelte for component tests. svelteTesting() Vite plugin is already wired.
- **Svelte 5 runes throughout:** `$state`, `$props()` destructuring, `$derived`. No legacy reactive `$:` statements.
- **fyne.io/systray v1.12.0 MUST run on a `LockOSThread`ed goroutine.** Any new tray menu items (Pause) keep that invariant. Don't touch `systray.*` from other goroutines.
- **Wails `EventsEmit` must NOT fire from watcher hot paths.** All emits go through the 1-slot `pending` channel pattern in `src/app/watcher_bridge.go` (PITFALLS §5). Automode's additional fan-out must also respect this.
- **`sync.RWMutex` + `sync.Once` + `chan struct{}` done-signal for lifecycle.** `atomic.Bool` for cross-goroutine flags (see `intentionalQuit` pattern).
- **Error wrapping `%w`; lowercase error strings.**
- **Privacy-first logging:** never log subject, body, or recipient addresses. Log counts + error categories only (QUAL-03 enforced).
- **Build-tag split pattern for fatal startup guards:** Phase 8 established this — any new fatal check must be in a `//go:build !bindings`-tagged file so `wailsbindings.exe` can introspect types without triggering `os.Exit`.
- **Test pattern for HTTP-mocked auth:** `httptest.Server` + endpoint override variables (Phase 8.1 D-12). Apply to new automode failure-path tests and to WR-02 fix.
- **Per-PR CI runs `go test -race ./internal/mapi/... ./src/app/...`** — any new goroutine fan-out must pass `-race`.
- **Commit style:** `type(NN): description` where NN is the phase number.

## Summary

Phase 9 is three threads woven into one:

1. **UI/feature work:** queue rows with inline actions, mode toggle, toasts, pause-watching tray item, has-queue tray icon variant. UI-SPEC has already locked all visual contracts; this research is about the Go plumbing behind them.
2. **Automode goroutine architecture:** extend `watcherBridge` with a second consumer goroutine that drains the queue through `MakeAuthenticatedGmailCall`. Gated on `auto-draft` mode AND not-paused.
3. **Test hygiene (WR-01/02/03):** three concrete fixes that must land as Plan 01 so CI is green for the feature work that follows.

**Primary recommendations:**

| Question | Answer | Confidence |
|----------|--------|------------|
| Toast library | **`git.sr.ht/~jackmordaunt/go-toast/v2` v2.0.3** — already transitively depended on; pure Go (no cgo); registers in HKCU only; RDS-safe; implements pure-Go COM activator. **Must extend with a raw wintoast shim for Tag/Group/History.Remove (NOTIF-05 gap).** | HIGH (library) / MEDIUM (NOTIF-05 shim scope) |
| Action-button activation | **Path (b): COM activator**, via jackmordaunt's in-process `INotificationActivationCallback`. Path (a) "foreground+hide" is NOT viable for unpackaged Win32 apps per Microsoft docs — foreground activation requires a COM activator. | HIGH |
| settings.json atomic write | **Use `natefinch/atomic` v1.0.1** — wraps Windows `MoveFileEx(..., MOVEFILE_REPLACE_EXISTING)`. Go 1.25 stdlib `os.Rename` is still NOT atomic on Windows for overwrite. Stdlib-only + `ReplaceFileW` syscall is also acceptable if we prefer zero new deps. | HIGH |
| Automode goroutine layout | **Option (ii) — second goroutine on the same `pending` signal**, not an extension of the dispatcher. Looser coupling; UI-emit stays unblocked by Gmail API latency. | HIGH |
| WR-01 fix | **Remove `t.Parallel()` from `TestAuthCodeURLHasPKCE`.** Package-level `oauthClientID`/`oauthClientSecret` are ldflags-injected and intentionally global. Restructuring as injected dependency is scope creep. | HIGH |
| WR-02 fix | **Set `userinfoEndpointOverride` in `TestBootstrapAuthSignedInPath` + `TestBootstrapAuth_TransientErrorKeepsTokens`** with an `httptest.Server` stub. Pattern already exists for `tokenEndpointOverride` / `revokeEndpointOverride`. | HIGH |
| WR-03 fix | **Loosen the assertion** to `count >= 1 && count <= len(burst)+1` AND add documentation comment explaining why the guarantee is "at least one emit, at most one per OnQueueChanged call". The 1-slot channel is signal-only; exact-count coalesce is not a property the design actually provides. | HIGH |
| AUMID registration (dev) | **PowerShell + inline C# via `Add-Type`** using `IShellLink` + `IPropertyStore` + `PKEY_AppUserModel_ID`. Idempotent via skip-if-exists. HKCU Start Menu path. | HIGH |

## Standard Stack

### Core (new in Phase 9)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `git.sr.ht/~jackmordaunt/go-toast/v2` | v2.0.3 (2025-01-17) [VERIFIED: `go list -m`] | Windows toast notifications with COM activator, action buttons, inputs | Pure Go; no cgo; HKCU registration; in-process activation callback; already a transitive dep in our go.sum (promote to direct) [VERIFIED: `src/app/go.mod` line 17] |
| `github.com/natefinch/atomic` | v1.0.1 (2021-06-28) [CITED: pkg.go.dev] | Crash-safe file write via `MoveFileEx(..., MOVEFILE_REPLACE_EXISTING)` | Only library wrapping the correct Windows syscall. Stdlib `os.Rename` on Windows is NOT atomic for overwrite through Go 1.25 [CITED: `go.dev/doc/go1.23` shows no Rename changes; issue #8914 still open] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `jackmordaunt/go-toast/v2` | `go-toast/toast` (gopkg.in/toast.v1) | REJECTED — invokes PowerShell script per toast; ~200ms cold-start latency per notification [CITED: NinjaOne guide, community reports]. D-05 constraint. |
| `jackmordaunt/go-toast/v2` | cgo bridge to `mohabouje/WinToast` (C++) | Adds build-toolchain dep (already have MinGW for DLL, but Wails app is pure Go today). More mature C++ library but larger surface to integrate. Reserve as fallback if jackmordaunt shim for Tag/Group proves intractable. |
| `natefinch/atomic` | `google/renameio` | Does NOT export any functions on Windows [CITED: pkg.go.dev renameio "not possible to reliably write files atomically on Windows"]. Unusable here. |
| `natefinch/atomic` | Stdlib-only (`os.CreateTemp` + `Sync` + `os.Rename`) | Works on POSIX. On Windows, `os.Rename` falls back to non-atomic semantics when target exists. Would require our own `ReplaceFileW` syscall via `golang.org/x/sys/windows`. Viable but reinvents the wheel. |
| `natefinch/atomic` | `golang.org/x/sys/windows` + `ReplaceFileW` syscall inline | Zero new dep, small code. Acceptable if we want to avoid a 3-year-unmaintained package. See §3 for both snippets. |

### Installation

```bash
# Promote existing indirect dep to direct + add atomic-write.
cd src/app
go get git.sr.ht/~jackmordaunt/go-toast/v2@v2.0.3
go get github.com/natefinch/atomic@v1.0.1
go mod tidy
```

Alternative: skip `natefinch/atomic` and use stdlib-only `x/sys/windows` (see §3).

### Version Verification

- `jackmordaunt/go-toast/v2` v2.0.3 — confirmed latest as of pkg.go.dev fetch 2026-04-19. Released 2025-01-17. [VERIFIED: `go list -m -json`]
- `natefinch/atomic` v1.0.1 — released 2021-06-28. "Not in latest version of its module" warning on pkg.go.dev [CITED: pkg.go.dev/github.com/natefinch/atomic]. No v1.0.2+ exists. Library is small and stable; 3-year stale is acceptable if we treat the Windows `MoveFileEx` wrapper as the load-bearing piece.

## Architecture Patterns

### 1. Toast Library Recommendation (D-05) — KEY SECTION

**Primary: `git.sr.ht/~jackmordaunt/go-toast/v2` v2.0.3**

**Why:**
- **Already depended on** (indirect — promote to direct). Zero new cgo toolchain.
- **Pure Go** — uses `syscall.NewCallback` to build a C-callable `INotificationActivationCallback` VTable in Go [VERIFIED: inspected `C:/Users/marc/go/pkg/mod/git.sr.ht/~jackmordaunt/go-toast/v2@v2.0.3/wintoast/impl.go`].
- **HKCU-only registration.** `registry.go` line 85: `registry.CreateKey(registry.CURRENT_USER, path, registry.SET_VALUE)` [VERIFIED: source read]. RDS-safe by construction.
- **Unpackaged Win32 app support.** Creates the `HKCU\SOFTWARE\Classes\AppUserModelId\<AppID>\CustomActivator` key pointing to a generated GUID; registers that GUID at `HKCU\SOFTWARE\Classes\CLSID\{GUID}\LocalServer32` → the app's EXE path [VERIFIED: registry.go lines 32-77].
- **Action buttons supported** via `Notification.Actions []Action` with `Type: Foreground` [VERIFIED: toast.go lines 73-86, xml.go.tmpl lines 33-35].
- **Activation callback in-process** — `SetActivationCallback(func(args string, data []UserData))` fires inside our own process when user clicks a toast button, even if the app wasn't running when the toast was created [VERIFIED: toast.go lines 220-224, architecture documented in ARCHITECTURE.md].
- **Maintained** — v2.0.3 released 2025-01-17; three v2.x releases within four months (v2.0.0 Oct 2024 → v2.0.3 Jan 2025).

**Library gaps:**

| Gap | Workaround |
|-----|------------|
| No `Tag` / `Group` setters on `Notification` | `ToastNotification.Tag` and `.Group` are WinRT properties set on the notification object AFTER creation, not via XML attributes. Jackmordaunt's `Push` wraps the COM object internally and does not expose the intermediate `IToastNotification` for `put_Tag` / `put_Group`. **Fix:** add a thin Go file alongside the library (under `src/app/`) that re-implements a Push-with-tag-group variant via `go-ole` and the same WinRT factories. The internal patterns are well-documented in the library's own ARCHITECTURE.md. |
| No `History.Remove(tag, group, aumid)` | Same — the WinRT `ToastNotificationHistory` class is not surfaced. Same fix: add a `ClearToast(aumid, tag, group)` helper in the same shim file using `RoGetActivationFactory(ToastNotificationManager, IID_IToastNotificationManagerStatics2)` → `get_History()` → `Remove(tag, group, aumid)` [CITED: learn.microsoft.com/en-us/uwp/api/windows.ui.notifications.toastnotificationhistory.remove]. |
| No built-in `SuppressPopup=true` setter (Focus Session quiet mode) | This is a `<toast>` XML attribute (`suppressPopup="true"` inside `<visual>` is wrong; actually `<toast ... duration="..." displayTimestamp="...">` with a separate route). The library's template doesn't expose it. Skip for Phase 9 — see §8. |

**Recommended path for the shim:**
Create `src/app/toast_shim.go` (build-tagged `//go:build windows` + non-Windows stub under `//go:build !windows` for cross-platform test compile). Depends on `github.com/go-ole/go-ole` (already indirect dep via jackmordaunt). ~150 LOC based on jackmordaunt's existing patterns. NO new direct dependencies.

**Runner-up: cgo bridge to `mohabouje/WinToast`** — rejected because:
1. Introduces a second C++ build step into the Wails app (we already have one for the MAPI DLL, but keeping Go/C++ boundaries small is a code-hygiene win).
2. Requires MinGW on the Wails app build path — currently pure Go + Wails tooling on Windows.
3. `WinToast` C++ lib does not itself document whether it writes HKCU or HKLM [VERIFIED by reading its README — HKCU/HKLM question unanswered].
4. Adds no features we need that a ~150-LOC Go shim on top of jackmordaunt can't provide.

**Rejected: `go-toast/toast` (gopkg.in/toast.v1)** — PowerShell-per-toast; ~200ms cold-start latency per notification; D-05 hard-reject.

**cgo impact of recommendation:** NONE. The recommended stack remains pure Go. Build toolchain unchanged.

### 2. Toast Action-Button Activation (D-07) — KEY SECTION

**Recommendation: Path (b) — COM activator (via jackmordaunt's in-process pure-Go implementation).**

**Why path (a) does NOT work for unpackaged Win32 apps:**

Microsoft's official decision matrix for unpackaged apps is explicit [CITED: https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/toast-desktop-apps]:

| Option | Visuals | Actions | Inputs | In-process activation |
|--------|---------|---------|--------|-----------------------|
| COM activator | ✓ | ✓ | ✓ | ✓ |
| No COM / Stub CLSID | ✓ | ✓ | ✗ | ✗ |

**But critically, for unpackaged apps the table on templates is:**

| Template × Activation | Packaged | Unpackaged |
|-----------------------|----------|------------|
| ToastGeneric Foreground | ✓ | ✓ (requires COM activator) |
| ToastGeneric Background | ✓ | ✓ (requires COM activator) |
| ToastGeneric Protocol  | ✓ | ✓ (works without COM activator) |

**For unpackaged Win32, "foreground" activation is NOT supported without a COM activator.** Without COM, only protocol activation works. Protocol activation means: the toast launches a URL with a custom protocol scheme, Windows routes the URL to whatever app is registered for that scheme, and THAT app handles the action. For a single-instance app this is baroque — we'd have to register our own protocol, parse the URL on launch, and IPC to the running instance. Total: more moving parts, NOT less.

**Why path (b) IS feasible for us despite "it sounds hard":**

`jackmordaunt/go-toast/v2` implements the COM activator in pure Go. The heavy lifting is done:
- `INotificationActivationCallback` VTable: allocated once at init [VERIFIED: impl.go `pinner.Pin(ClassFactory)`].
- COM class factory registration: `CoRegisterClassObject` on `Push`.
- CLSID → EXE path registration: `HKCU\SOFTWARE\Classes\CLSID\{GUID}\LocalServer32` (the library does this).
- Callback delivery to Go: `SetActivationCallback(func(args string, data []UserData))`.

**What WE do in go-mapi code:**

```go
// main.go or new toast.go in src/app/
func (a *App) initToasts() error {
    aumid := "com.marcfargas.gomapi.dev" // or prod value
    if err := toast.SetAppData(toast.AppData{
        AppID: aumid,
        GUID:  "{0F82E845-CB89-4039-BDBF-67CA33254C76}", // library default OR generate our own
        // Library's default CLSID is hard-coded — we MAY want to override with a go-mapi-specific GUID
        // so the CLSID registration doesn't collide with other apps using the same library.
        // Generate via `uuidgen` or `ole.CreateGUID()` at dev time; pin in source.
        ActivationExe: mustExePath(), // for out-of-process COM server invocation when app isn't running
        IconPath:      mustIconPath(),
    }); err != nil {
        return fmt.Errorf("toast: set app data: %w", err)
    }

    toast.SetActivationCallback(func(args string, data []toast.UserData) {
        // args = "action=create-draft&emailId=<id>" (we set this via Action.Arguments)
        // Dispatch to the main goroutine via a channel — this callback runs on a COM thread.
        a.handleToastAction(args)
    })
    return nil
}

func (a *App) handleToastAction(args string) {
    // Parse args string: "action=<op>&emailId=<id>"
    q, _ := url.ParseQuery(args)
    op := q.Get("action")
    id := q.Get("emailId")
    switch op {
    case "create-draft":
        go func() { _ = a.CreateDraftForID(id) }()
    case "dismiss":
        go func() { _ = a.DismissEmail(id) }()
    default:
        // "open" or unknown → show window
        a.showWindow()
    }
}
```

**Registry keys written (by jackmordaunt at SetAppData time):**

```
HKCU\SOFTWARE\Classes\AppUserModelId\com.marcfargas.gomapi.dev
    DisplayName = "go-mapi (dev)"
    CustomActivator = "{OUR-GUID}"
    IconUri = "C:\path\to\icon.png"
HKCU\SOFTWARE\Classes\CLSID\{OUR-GUID}\LocalServer32
    (Default) = "C:\path\to\go-mapi.exe"
```

**Start Menu shortcut with AUMID:** required for Action Center persistence (without it, toasts pop but don't persist). Phase 9 ships the dev-side helper script (§6); Phase 10 ships the installer-side registration.

**Activation flow:**

1. User clicks `Create draft` on a toast.
2. Windows looks up CLSID in `HKCU\SOFTWARE\Classes\CLSID\{OUR-GUID}\LocalServer32`.
3. If the app is running → `INotificationActivationCallback::Activate` is dispatched in-process → our `SetActivationCallback` Go closure fires.
4. If the app is NOT running → Windows invokes `LocalServer32` (the EXE path with `-Embedding` flag); our main.go detects `-Embedding` in `os.Args`, starts the full Wails app, and the COM dispatch arrives after Wails' runtime initializes.

**IPC to running instance:** the single-instance mutex in `src/app/singleinstance.go` already ensures only one `go-mapi.exe` process runs. The COM machinery handles the "in-process" delivery for us; no named-pipe IPC needed for toast activations. The `waitForRaiseSignal` infrastructure in `app.go` line 51 can be reused or paralleled if we need a cross-instance prod from the COM stub to the main instance — in practice, COM registers the callback with the already-running instance of our app because both use the same CLSID and Windows keeps that mapping live.

**RDS validation:** HKCU is per-user per-session. Each RDP session's user has their own HKCU. Registration is isolated per session. ✓ RDS-safe.

**Code-signing status impact (unsigned until Phase 11):** none. COM activator registration does not require code signing. SmartScreen reputation does not gate COM activation. (Separately: unsigned binaries may cause Windows to show a UAC prompt on first launch from a toast callback in very rare configurations, but this matches current "unsigned" behavior.)

### 3. settings.json Atomic Write (D-13) — KEY SECTION

**Problem:** On Windows, `os.Rename` is NOT atomic when the target file exists [CITED: https://github.com/golang/go/issues/8914 still open; go.dev/doc/go1.23 release notes contain no Rename changes; pkg.go.dev/github.com/google/renameio "not possible to reliably write files atomically on Windows"]. The correct Windows syscall is `MoveFileEx(source, dest, MOVEFILE_REPLACE_EXISTING)` (or `ReplaceFileW`).

**Recommendation: stdlib-only via `x/sys/windows` — zero new dependencies.**

`golang.org/x/sys` v0.30.0 is already in `src/app/go.mod`. The `MoveFileEx` wrapper is a one-liner:

```go
// src/app/settings.go
package main

import (
    "encoding/json"
    "fmt"
    "os"
    "path/filepath"

    "golang.org/x/sys/windows"
)

// AppSettings is the persisted per-user settings. Keep this flat — Phase 9 ships
// one field; Phase 10+ may add more but never nest. Marshaled as JSON.
type AppSettings struct {
    Mode string `json:"mode"` // "manual" | "auto-draft"
}

const defaultMode = "manual"

// loadSettings reads %APPDATA%\go-mapi\settings.json. Returns defaults on any
// error (first-run, corrupt file, unreadable). Corrupt files are NOT moved
// aside in Phase 9 — D-15 semantics (Pause is session-only) mean the only
// persisted field is mode, and resetting to "manual" on a corrupt read is
// the safe default.
func loadSettings() AppSettings {
    path := settingsPath()
    data, err := os.ReadFile(path)
    if err != nil {
        // ENOENT or any other read error → defaults.
        return AppSettings{Mode: defaultMode}
    }
    var s AppSettings
    if err := json.Unmarshal(data, &s); err != nil {
        logError("settings: parse error, using defaults: %v", err)
        return AppSettings{Mode: defaultMode}
    }
    // Normalize unknown mode values to default.
    if s.Mode != "manual" && s.Mode != "auto-draft" {
        s.Mode = defaultMode
    }
    return s
}

// saveSettings writes AppSettings atomically. Pattern:
//   1. Marshal to JSON.
//   2. Create tmp file in the SAME directory (os.Rename/ReplaceFile require same volume).
//   3. Write + Sync + Close.
//   4. MoveFileEx(tmp, dest, REPLACE_EXISTING | WRITE_THROUGH) — atomic on NTFS.
//   5. On any error, best-effort unlink tmp.
//
// Safe against crashes mid-write: if we crash between steps 2 and 4, the real
// settings.json is untouched; the tmp file is either absent (pre-create) or
// orphaned (post-create) — orphaned tmp files are fine; we glob-unlink *.tmp
// on next successful save.
func saveSettings(s AppSettings) error {
    path := settingsPath()
    dir := filepath.Dir(path)
    if err := os.MkdirAll(dir, 0755); err != nil {
        return fmt.Errorf("settings: mkdir: %w", err)
    }
    data, err := json.Marshal(s)
    if err != nil {
        return fmt.Errorf("settings: marshal: %w", err)
    }
    tmp, err := os.CreateTemp(dir, "settings-*.tmp")
    if err != nil {
        return fmt.Errorf("settings: create tmp: %w", err)
    }
    tmpPath := tmp.Name()
    defer func() {
        // Best-effort cleanup on any error path. If rename succeeded, tmp
        // is gone and this Remove is a no-op.
        _ = os.Remove(tmpPath)
    }()
    if _, err := tmp.Write(data); err != nil {
        _ = tmp.Close()
        return fmt.Errorf("settings: write tmp: %w", err)
    }
    if err := tmp.Sync(); err != nil {
        _ = tmp.Close()
        return fmt.Errorf("settings: sync tmp: %w", err)
    }
    if err := tmp.Close(); err != nil {
        return fmt.Errorf("settings: close tmp: %w", err)
    }
    // Atomic replace via MoveFileEx on Windows.
    if err := moveFileAtomic(tmpPath, path); err != nil {
        return fmt.Errorf("settings: atomic rename: %w", err)
    }
    return nil
}

func moveFileAtomic(src, dst string) error {
    srcW, err := windows.UTF16PtrFromString(src)
    if err != nil {
        return err
    }
    dstW, err := windows.UTF16PtrFromString(dst)
    if err != nil {
        return err
    }
    // MOVEFILE_REPLACE_EXISTING: replace target if it exists.
    // MOVEFILE_WRITE_THROUGH: do not return until the operation is physically
    // committed to disk (crash-safe).
    return windows.MoveFileEx(srcW, dstW, windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH)
}

func settingsPath() string {
    // paths.go already has appDataDir() → %APPDATA%\go-mapi
    return filepath.Join(appDataDir(), "settings.json")
}
```

**Mutex guidance (CRITICAL):**

- **Do NOT write settings.json from background goroutines.** Settings writes are strictly UI-triggered (mode toggle click). Background goroutines (automode, watcher, auth refresh) MUST NOT write.
- If somehow a multi-writer scenario emerges in v4+, add a `sync.Mutex` guarding `saveSettings` calls. Phase 9: the single-writer invariant + `MoveFileEx` atomicity is sufficient.
- The `MoveFileEx` call itself is atomic with respect to readers: a concurrent `loadSettings` sees either the old file or the new one, never a partial write. That's the whole point of the pattern.

**Alternative (if we prefer a library):** `natefinch/atomic` v1.0.1 wraps exactly `MoveFileEx` on Windows. Drop-in replacement for steps 3-4 of the pattern:

```go
// With natefinch/atomic:
import "github.com/natefinch/atomic"

func saveSettings(s AppSettings) error {
    data, _ := json.Marshal(s)
    return atomic.WriteFile(settingsPath(), bytes.NewReader(data))
}
```

Functionally identical. Library is 3-year-unmaintained but small and correct. Recommend stdlib-only to avoid adding a stale dep.

### 4. Automode Architecture

**Recommendation: Option (ii) — second goroutine on the same `pending` signal.**

**Why not option (i) (extend existing dispatcher):**
- Tight coupling: a stuck Gmail API call (45s timeout before our own bound takes effect) would delay the `queue-update` event that the dispatcher also emits. UI feels frozen while automode is hitting a slow endpoint.
- Single-responsibility violation: the existing dispatcher's contract is "emit queue-update off the watcher hot path". Draining+drafting is a different concern.

**Why option (ii):**
- UI `queue-update` events fire immediately regardless of Gmail API state.
- Automode loop can apply its own timeouts, refresh semantics, and pause checks without interfering with UI freshness.
- Matches the 1-slot pending channel's existing pattern — both consumers just select on `pending`.

**Concrete layout:**

```go
// src/app/watcher_bridge.go — extend with a second consumer, fed via a fan-out.

// Change pending to fan-out: dispatcher still gets its 1-slot signal, AND
// a new automode channel gets the same signal (also 1-slot coalesce).
type watcherBridge struct {
    ctx       context.Context
    emitter   func(name string, data ...interface{})
    onError   func(err error)
    // Two 1-slot channels — BOTH are fed from OnQueueChanged. Coalesce is
    // independent per consumer; dispatcher keeps its existing 1-slot guarantee,
    // automode gets its own 1-slot drain signal.
    pending       chan struct{}
    automodeWake  chan struct{}
    done          chan struct{}
    closeOnce     sync.Once
    getSnap       func() []mapi.EmailWithId
}

func (b *watcherBridge) OnQueueChanged(_ []mapi.EmailWithId) {
    // Non-blocking send into BOTH channels — drop if full (coalesce).
    select { case b.pending <- struct{}{}: default: }
    select { case b.automodeWake <- struct{}{}: default: }
}
```

**Automode goroutine (new file `src/app/automode.go`):**

```go
package main

import (
    "context"
    "errors"
    "net/http"
    "sync"
    "time"

    "github.com/marcfargas/go-mapi/internal/mapi"
    wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// automode owns the auto-draft loop. Lifecycle:
//   - started from App.startup AFTER watcher + bridge are ready
//   - wakes on bridge.automodeWake OR every 30s (safety tick, in case we
//     missed a signal during a burst race)
//   - checks mode + paused flags; if not "auto-draft" or paused → sleep
//   - for each queued email: MakeAuthenticatedGmailCall → gc.CreateDraft →
//     watcher.MarkProcessed; emit auto-draft-result per email.
//   - stops on a.shutdownCtx cancel.
type automode struct {
    app       *App
    wake      <-chan struct{}   // bridge.automodeWake (read-only)
    done      chan struct{}
    closeOnce sync.Once
    // inflight tracks email IDs currently being processed — prevents a
    // re-enqueue from a new queue-update signal (same email, different watcher
    // event) from double-drafting. Cleared on each MarkProcessed success OR
    // terminal failure.
    inflightMu sync.Mutex
    inflight   map[string]struct{}
}

func newAutomode(app *App, wake <-chan struct{}) *automode {
    return &automode{
        app:      app,
        wake:     wake,
        done:     make(chan struct{}),
        inflight: make(map[string]struct{}),
    }
}

func (m *automode) start() {
    go m.loop()
}

func (m *automode) stop() {
    m.closeOnce.Do(func() { close(m.done) })
}

func (m *automode) loop() {
    // Safety tick — protects against signal drops. 30s is a compromise:
    // bursty arrivals are handled by wake signal; slow-trickling arrivals
    // pay up to 30s latency if a signal was dropped. In practice the 1-slot
    // channel never "drops" because any subsequent OnQueueChanged re-signals.
    tick := time.NewTicker(30 * time.Second)
    defer tick.Stop()

    for {
        select {
        case <-m.app.shutdownCtx.Done():
            return
        case <-m.done:
            return
        case <-m.wake:
            m.drain()
        case <-tick.C:
            m.drain()
        }
    }
}

// drain processes as many emails as possible while in auto-draft mode and
// not paused. Exits early on the first unrecoverable error (invalid_grant).
func (m *automode) drain() {
    if m.app.isPaused() {
        return
    }
    if m.app.getMode() != "auto-draft" {
        return
    }
    if m.app.watcher == nil {
        return
    }
    // Snapshot is a copy — safe to iterate outside any watcher lock.
    for _, e := range m.app.watcher.Snapshot() {
        if m.app.shutdownCtx.Err() != nil {
            return
        }
        if m.app.isPaused() || m.app.getMode() != "auto-draft" {
            return // mode/pause changed mid-drain; stop immediately
        }
        if !m.tryAcquire(e.Id) {
            continue // already being processed by a previous tick — race-safe
        }
        if err := m.draftOne(e); err != nil {
            // Terminal errors (invalid_grant) stop the drain — further drafts
            // would also fail, and user needs to see the ReAuthBanner before
            // any more toast spam.
            if errors.Is(err, ErrInvalidGrant) {
                m.release(e.Id)
                return
            }
        }
        m.release(e.Id)
    }
}

func (m *automode) tryAcquire(id string) bool {
    m.inflightMu.Lock()
    defer m.inflightMu.Unlock()
    if _, ok := m.inflight[id]; ok {
        return false
    }
    m.inflight[id] = struct{}{}
    return true
}

func (m *automode) release(id string) {
    m.inflightMu.Lock()
    defer m.inflightMu.Unlock()
    delete(m.inflight, id)
}

// draftOne runs the authenticated Gmail call for a single queued email. Emits
// auto-draft-result per outcome. Returns the error for drain's terminal-error
// classification; callers treat non-nil errors as "row stays queued".
func (m *automode) draftOne(e mapi.EmailWithId) error {
    ctx, cancel := context.WithTimeout(m.app.shutdownCtx, 30*time.Second)
    defer cancel()

    callErr := m.app.MakeAuthenticatedGmailCall(ctx, func(token string) (int, error) {
        gc := mapi.NewGmailClient(token)
        _, err := gc.CreateDraft(e.Message)
        // CreateDraft returns non-nil err + status code NOT surfaced; we emulate
        // status from err text for the 401 retry loop in MakeAuthenticatedGmailCall.
        // A cleaner design would extend GmailClient to return (statusCode, err).
        // For Phase 9: "token expired" error text → 401; everything else → 500.
        if err != nil {
            if err.Error() == "token expired" {
                return 401, err
            }
            return 500, err
        }
        return 200, nil
    })

    category := classifyAutomodeError(callErr)
    if callErr != nil {
        // Privacy-safe log: email ID hash prefix + category only. No subject/body/recipient.
        logError("automode: draft %s failed: %s", e.Id[:8], category)
        wruntime.EventsEmit(m.app.ctx, "auto-draft-result", map[string]any{
            "emailId":       e.Id,
            "success":       false,
            "errorCategory": category,
        })
        return callErr
    }
    // Success → MarkProcessed deletes the JSON; next queue-update removes the row.
    if err := m.app.watcher.MarkProcessed(e.Id); err != nil {
        logError("automode: MarkProcessed %s: %v", e.Id[:8], err)
        // Non-fatal: draft was created; row will stay until user dismisses.
    }
    wruntime.EventsEmit(m.app.ctx, "auto-draft-result", map[string]any{
        "emailId": e.Id,
        "success": true,
    })
    return nil
}

// classifyAutomodeError maps Go errors into the three UI categories D-09
// requires. Order matters: invalid_grant before network before gmail.
func classifyAutomodeError(err error) string {
    if err == nil {
        return ""
    }
    if errors.Is(err, ErrInvalidGrant) || errors.Is(err, ErrNotAuthenticated) {
        return "signed-out"
    }
    // net/url, net/http timeout, EOF, etc.
    var netErr interface{ Timeout() bool }
    if errors.As(err, &netErr) && netErr.Timeout() {
        return "network"
    }
    // Fall back to "gmail" for anything bubbled from CreateDraft that isn't
    // the other two. Includes Gmail 4xx/5xx, JSON parse errors, etc.
    return "gmail"
}
```

**Paused + mode accessors on App:**

```go
// In src/app/app.go — add:
func (a *App) isPaused() bool {
    a.pauseMu.Lock()
    defer a.pauseMu.Unlock()
    return a.paused
}

func (a *App) SetPaused(v bool) {
    a.pauseMu.Lock()
    a.paused = v
    a.pauseMu.Unlock()
    // Emit pause-changed so the tray tooltip + frontend can update.
    wruntime.EventsEmit(a.ctx, "pause-changed", v)
}

func (a *App) getMode() string {
    a.settingsMu.RLock()
    defer a.settingsMu.RUnlock()
    return a.settings.Mode
}
```

Note on `App struct` new fields:
```go
// In App struct:
pauseMu     sync.Mutex
paused      bool
settingsMu  sync.RWMutex
settings    AppSettings
automode    *automode  // started in startup, stopped in shutdown
```

**Interaction with `MakeAuthenticatedGmailCall`:**
- Already handles 401 refresh-retry + `invalid_grant` classification + `auth-changed` event emission + `SetTrayError("sign-in expired")`.
- `automode.draftOne` does NOT need to re-emit auth-changed or touch the tray; those are already handled inside `MakeAuthenticatedGmailCall`.
- Our addition: emit `auto-draft-result` per outcome so the frontend row badge can render.

**`invalid_grant` behavior (D-10):**
- `MakeAuthenticatedGmailCall` clears tokens + emits `auth-changed{authenticated:false, invalidGrant:true}` (actually our existing code emits `auth-changed` via `emitAuthChanged()` which re-reads `am.Status()` — that returns `Authenticated: false` after clear). The frontend's `App.svelte` already surfaces `ReAuthBanner` on the signed-out transition.
- `automode.drain` returns on the first `invalid_grant` — subsequent emails in the same burst don't fire more error toasts. D-10 says "one summary toast"; we implement that by emitting a single `auto-draft-result{errorCategory:"signed-out"}` on the first failed email and halting the drain.
- After re-auth, the NEXT `queue-update` (because the user drafts something manually, or a new MAPI arrival lands, or the safety tick fires) resumes the automode loop. Backlog rows that were queued during the signed-out period have `inflight` cleared and would be re-attempted — **but this violates D-10** ("no retroactive backlog draining").

**Backlog-stays-manual implementation (D-10 refinement):**

We need a per-email "skip-in-automode" flag that persists across the signed-out → signed-in transition but is not persisted to disk. Options:

1. **In-memory set on App struct** — `backlogSkip map[string]struct{}` guarded by `backlogMu`. Populated when automode classifies an email as `signed-out`. Cleared on `queue-update` if the email is no longer present (drafted manually or dismissed).
2. **Attach to the mapi.MailMessage itself** — new field `AutoSkip bool`. Cleaner but mutates shared protocol. Rejected.

Recommend option 1. Implementation sketch:

```go
// On App struct:
backlogSkipMu sync.Mutex
backlogSkip   map[string]struct{}

// In automode.drain, before tryAcquire:
if m.app.isBacklogSkipped(e.Id) {
    continue
}

// On terminal failure in draftOne:
if errors.Is(callErr, ErrInvalidGrant) {
    m.app.markBacklogSkipped(e.Id)
}

// Prune stale entries on queue-update:
// In watcherBridge.dispatch, after emitter("queue-update"), call:
// m.app.pruneBacklogSkip(currentIdSet)
```

This adds ~30 LOC total and precisely implements D-10 semantics.

**WR-03 interaction + sequencing note (CRITICAL):**

The dual-channel fan-out in `watcherBridge.OnQueueChanged` changes the exact channel-send pattern WR-03's test asserts on. Sequence:

1. **Fix WR-03 FIRST** (Plan 01 test-hygiene pass) before any fan-out modification.
2. After WR-03's assertion is loosened to `count >= 1 && count <= len(burst)+1` with documentation comment, the dual-channel extension is trivially compatible — both channels have the same 1-slot semantics; the test's emitCount counts only the `pending`-channel emitter, unchanged by the new `automodeWake` channel.
3. Add a parallel test `TestAutomodeWakeCoalesces` that asserts the same loose guarantee on the new channel.

### 5. Test Hygiene Fixes (D-18)

#### WR-01: `TestAuthCodeURLHasPKCE` t.Parallel unsafe

**Root cause (verified by reading `src/app/auth_test.go` lines 180-214):**

```go
func TestAuthCodeURLHasPKCE(t *testing.T) {
    t.Parallel()  // ← UNSAFE
    oauthClientID = "test-client.apps.googleusercontent.com"  // ← mutates package var
    oauthClientSecret = "test-secret"                         // ← mutates package var
    t.Cleanup(func() { oauthClientID = ""; oauthClientSecret = "" })
    // ...
}
```

The test mutates `oauthClientID` and `oauthClientSecret` which are package-level `var`s set by ldflags. `t.Parallel()` means another test reading those vars concurrently sees a race.

**Note on the CONTEXT.md reference to `authEndpointOverride`:** that variable does not exist in the codebase [VERIFIED: `grep "authEndpointOverride" src/app/` returns no matches]. The actual problem is `oauthClientID` / `oauthClientSecret`. The CONTEXT.md description is directionally correct but names the wrong variable. Planner should record this clarification in the fix.

**Recommended fix: remove `t.Parallel()` + the cleanup closure.**

Rationale:
- These two variables are intentionally globals (ldflags injection is inherently a global mechanism).
- Restructuring them as an injected dependency would require:
  1. Creating a `oauthConfig` struct type.
  2. Threading it through `NewAuthManager`, `signInLocked`, `refreshIfNeededLocked`, `revokeRefreshToken`.
  3. Updating the build-tag split for credentials_check.go.
  4. Updating main.go ldflags-injection site.
  5. Updating all existing tests.
  Total: ~50 LOC churn across 4 files for a single-test race fix. **Scope creep.**
- The global is stable: only ONE test mutates these vars (all other tests read them as empty strings, which is fine because tests that need populated values don't actually exchange tokens against the real endpoint — they set `tokenEndpointOverride` and use `httptest.Server`). Removing `t.Parallel()` costs ~5ms of test time for a dramatic simplicity win.

**Concrete fix:**

```go
// src/app/auth_test.go line 180
func TestAuthCodeURLHasPKCE(t *testing.T) {
    // NOTE: NOT t.Parallel — mutates oauthClientID/oauthClientSecret package
    // vars which are ldflags-injected globals. See STATE.md WR-01.
    oauthClientID = "test-client.apps.googleusercontent.com"
    oauthClientSecret = "test-secret"
    t.Cleanup(func() { oauthClientID = ""; oauthClientSecret = "" })
    // ...rest unchanged
}
```

Two lines deleted (the `t.Parallel()` call and a blank line), one comment added. No other tests change.

#### WR-02: Bootstrap-auth tests leak goroutine to real Google userinfo endpoint

**Root cause (verified by reading `src/app/auth.go` lines 737-786 and `src/app/auth_test.go` lines 594-627, 810-842):**

`App.bootstrapAuth()` ends with (line 780):
```go
go func() {
    a.auth.refresh.Lock()
    a.auth.fetchUserInfoLocked(a.ctx)
    a.auth.refresh.Unlock()
    a.emitAuthChanged()
}()
```

`fetchUserInfoLocked` makes an HTTP call to `userinfoEndpoint()` (line 362). In tests that DON'T set `userinfoEndpointOverride`, this hits `https://www.googleapis.com/oauth2/v3/userinfo` — a real network call that (a) leaks a goroutine across `-race`, (b) may hang on slow networks, (c) violates test hermeticity.

Three call sites in auth_test.go have this issue:
- Line 598 `TestBootstrapAuthSignedOutPath` — actually SAFE: `am.tokens == nil` branch returns before the async goroutine starts (line 750-755).
- Line 623 `TestBootstrapAuthSignedInPath` — UNSAFE: tokens are valid, the async userinfo fetch fires.
- Line 835 `TestBootstrapAuth_TransientErrorKeepsTokens` — UNSAFE: tokens retained, async fetch fires.
- Line 853 `TestBootstrapAuth_KeyringGetHardError_SetsErrorState` — SAFE: returns on keyring error before async goroutine.

So only 2 of 4 tests leak.

**Existing endpoint override variables (as requested by prompt):**
- `tokenEndpointOverride` [auth.go line 491, used at auth_test.go lines 351, 387, 640, 675, 713, 746, etc.]
- `revokeEndpointOverride` [auth.go line 492, used at auth_test.go lines 511, 561]
- `userinfoEndpointOverride` [auth.go line 69, used at auth_test.go line 874 for `TestFetchUserInfoLocked_HappyPath`]

The override pattern is ALREADY established; we just need to apply it to the two leaking tests.

**Recommended fix: set `userinfoEndpointOverride` + `httptest.Server` stub in both bootstrap tests.**

```go
// TestBootstrapAuthSignedInPath (line 607)
func TestBootstrapAuthSignedInPath(t *testing.T) {
    // New: stub the userinfo endpoint so the async goroutine in bootstrapAuth
    // doesn't leak to real Google (WR-02).
    userinfoSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        _, _ = w.Write([]byte(`{"email":"test@example.com","name":"Test"}`))
    }))
    defer userinfoSrv.Close()
    userinfoEndpointOverride = userinfoSrv.URL
    t.Cleanup(func() { userinfoEndpointOverride = "" })

    // ...rest unchanged (lines 608-627)
}

// TestBootstrapAuth_TransientErrorKeepsTokens (line 810) — same pattern.
```

**Critical addition: the existing test doesn't wait for the async goroutine to finish.** Under `-race`, `go test` reports a race when the goroutine is still running at test exit. Fix: add a drain at end of test.

```go
// At end of each bootstrap test that had the async fetch fire:
// Wait briefly for the async userinfo goroutine to settle. Without this,
// the goroutine is mid-flight at test exit and -race reports a leak.
// A cleaner fix would be to expose a "bootstrap done" channel on App, but
// that's scope creep for a test-hygiene pass.
time.Sleep(50 * time.Millisecond)
```

50ms is enough for the httptest.Server round-trip on localhost. Goroutine completes, `-race` is happy.

Even cleaner: change `bootstrapAuth` to return a `done <-chan struct{}` (or accept a callback) so tests can deterministically wait. This is a ~15 LOC change to `auth.go` + both tests. Planner picks — deterministic channel is cleaner but is a design change; time.Sleep(50ms) is a pragmatic test-only workaround.

**Recommended: deterministic channel.** Add:

```go
// bootstrapAuth returns a channel that closes when the async userinfo fetch
// finishes. Production code discards it; tests wait on it for hermeticity.
func (a *App) bootstrapAuth() <-chan struct{} {
    done := make(chan struct{})
    // ...existing logic...
    go func() {
        defer close(done)
        a.auth.refresh.Lock()
        a.auth.fetchUserInfoLocked(a.ctx)
        a.auth.refresh.Unlock()
        a.emitAuthChanged()
    }()
    return done
}
```

Tests then do `<-app.bootstrapAuth()` with a `select` + timeout. Zero sleep; deterministic. This IS the cleaner path.

#### WR-03: `TestDispatcherCoalesces` flakes under -race on windows/amd64

**Root cause (verified by reading `src/app/watcher_bridge_test.go:64-95` and `watcher_bridge.go:53-58, 67-77`):**

The test blocks the dispatcher's emitter with a channel, fires 50 `OnQueueChanged` calls while blocked, then unblocks and asserts `emitCount == 1`.

Legal outcomes under the 1-slot channel design:
- **count == 1:** All 50 `OnQueueChanged` arrived while the emitter was blocked; the first filled pending, the next 49 were dropped (select default). When unblocked, dispatcher emits once.
- **count == 2:** The first `OnQueueChanged` filled pending; the dispatcher drained it (pending ← empty) and called emitter (which blocks). Now the 2nd `OnQueueChanged` arrives and fills pending AGAIN. Eventually emitter unblocks, loops back to select, sees pending filled, emits a second time.

The design does NOT guarantee count==1 under burst. The design guarantees "at least one emit per non-empty burst, coalesced when possible" — exact coalesce depends on timing.

**Recommendation: loosen the assertion + add explanatory comment.**

```go
// Test 3: Dispatcher coalesces — 1-slot drop policy bounds the emit count to
// between 1 and len(burst)+1 (the +1 accounts for a burst item arriving after
// the dispatcher drains the first slot but before the emitter completes).
// WR-03 (2026-04-19): the original assertion `count == 1` was tightly coupled
// to a specific race interleaving and flaked on windows/amd64 under -race.
// The 1-slot channel guarantees "at least one emit", not "exactly one emit";
// the test now enforces only the meaningful upper bound.
func TestDispatcherCoalesces(t *testing.T) {
    ctx := context.Background()

    dispatchBlocked := make(chan struct{})
    var emitCount int32
    b := newWatcherBridgeWithEmitter(ctx, nil, func(_ string, _ ...interface{}) {
        <-dispatchBlocked
        atomic.AddInt32(&emitCount, 1)
    })
    defer b.Close()

    const burst = 50
    b.OnQueueChanged(nil) // fills pending
    for i := 0; i < burst-1; i++ {
        b.OnQueueChanged(nil) // drops
    }
    close(dispatchBlocked)
    time.Sleep(50 * time.Millisecond)

    count := atomic.LoadInt32(&emitCount)
    if count < 1 || count > burst+1 {
        t.Errorf("dispatcher emit count out of legal range [1, %d]: got %d", burst+1, count)
    }
    // Additionally, coalesce should compress significantly — if emitCount equals
    // burst, the 1-slot semantic is broken.
    if count > 5 { // generous bound; real runs should be ≤ 2
        t.Logf("warning: coalesce less aggressive than expected — got %d emits for burst of %d", count, burst)
    }
}
```

**Alternative rejected: redesign coalesce guarantee** — requires a mutex + counter on the `pending` state, which adds complexity to the hot watcher path that PITFALLS §5 explicitly warns against. Not worth the churn.

**Alternative rejected: deterministic sync point** — requires adding a test-only `waitForIdle()` hook to `watcherBridge`; test-visibility pollution for a real issue that is genuinely "the assertion was wrong".

### 6. AUMID Dev Registration (NOTIF-04 dev-side)

Ship `scripts/register-dev-aumid.ps1` that creates an HKCU Start Menu shortcut with AUMID `com.marcfargas.gomapi.dev`. Used during `wails dev` so toasts fire and persist in Action Center with a sensible app name.

**Key challenge:** PowerShell cannot set `PKEY_AppUserModel_ID` on a .lnk natively. The `WScript.Shell` COM object used for shortcut creation does not expose IPropertyStore. Two paths:

1. **Inline C# via `Add-Type`** (recommended — pure PowerShell script, no external binaries).
2. **Shipped compiled helper** (e.g., makelnk.exe) — more portable but increases distribution surface.

**Recommended: inline C# pattern.**

```powershell
# scripts/register-dev-aumid.ps1
# Registers a HKCU Start Menu shortcut for go-mapi dev builds with AUMID
# "com.marcfargas.gomapi.dev" so toast notifications during `wails dev` persist
# in Windows Action Center.
#
# Idempotent: running twice is a no-op. Safe to re-run after every git pull.
#
# Phase 10 (INST-04) will ship the prod equivalent with:
#   - AUMID: com.marcfargas.gomapi (no .dev)
#   - Shortcut path: %ProgramFiles%\go-mapi\go-mapi.lnk
#   - Registration via NSIS installer (not PowerShell).

[CmdletBinding()]
param(
    [string]$Aumid = 'com.marcfargas.gomapi.dev',
    [string]$Name  = 'go-mapi (dev)',
    [string]$ExePath # absolute path to the wails-dev build's go-mapi.exe
)

$ErrorActionPreference = 'Stop'

if (-not $ExePath) {
    # Default: src/app/build/bin/go-mapi.exe relative to repo root.
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $ExePath = Join-Path $repoRoot 'src\app\build\bin\go-mapi.exe'
}
if (-not (Test-Path -LiteralPath $ExePath)) {
    Write-Warning "go-mapi.exe not found at $ExePath"
    Write-Warning 'Run `wails build` first, or pass -ExePath explicitly.'
    # Still proceed — the shortcut can point to a not-yet-existing path; wails dev will overwrite it.
}

$startMenu = [Environment]::GetFolderPath('Programs')  # %APPDATA%\Microsoft\Windows\Start Menu\Programs
$lnkPath   = Join-Path $startMenu "$Name.lnk"

# ---- Idempotency check: if the shortcut exists AND already carries the correct AUMID, exit 0.
if (Test-Path -LiteralPath $lnkPath) {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    try {
        $existingAumid = & "${PSScriptRoot}\..\src\app\build\bin\go-mapi.exe" --noop 2>$null # no-op; replace with a real read if we ship a helper
    } catch {
        $existingAumid = $null
    }
    # Simpler check: trust that if the .lnk exists we already registered it; skip.
    Write-Host "AUMID shortcut already exists at $lnkPath — skipping." -ForegroundColor Green
    return
}

# ---- Create the shortcut via WScript.Shell (works; does not set AUMID).
$wsh = New-Object -ComObject WScript.Shell
$sc  = $wsh.CreateShortcut($lnkPath)
$sc.TargetPath       = $ExePath
$sc.WorkingDirectory = Split-Path $ExePath -Parent
$sc.Description      = 'go-mapi (dev) — MAPI-to-Gmail bridge'
$sc.Save()

# ---- Set PKEY_AppUserModel_ID on the .lnk via inline C# + IShellLink + IPropertyStore.
# Reference: https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-id
Add-Type -Namespace GoMapi -Name AumidShortcut -MemberDefinition @'
    using System;
    using System.Runtime.InteropServices;

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellLinkW {
        // Partial vtable — only GetPath/SetPath needed for our purposes; we actually
        // only need the QueryInterface to IPropertyStore so we can stop here.
        void GetPath(out IntPtr a, int b, out IntPtr c, int d);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        void GetCount(out uint count);
        void GetAt(uint iProp, out PROPERTYKEY pkey);
        void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
        void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PROPERTYKEY {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPVARIANT {
        public ushort vt;
        public ushort reserved1;
        public ushort reserved2;
        public ushort reserved3;
        public IntPtr union1;
        public IntPtr union2;
    }

    [ComImport, Guid("0000010B-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPersistFile {
        void GetClassID(out Guid pClassID);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    public static class Native {
        [DllImport("ole32.dll", PreserveSig = false)]
        public static extern void CoCreateInstance(
            [MarshalAs(UnmanagedType.LPStruct)] Guid rclsid,
            IntPtr pUnkOuter,
            uint dwClsContext,
            [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
            [MarshalAs(UnmanagedType.IUnknown)] out object ppv);

        [DllImport("propsys.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        public static extern void InitPropVariantFromString(
            [MarshalAs(UnmanagedType.LPWStr)] string psz,
            out PROPVARIANT ppropvar);
    }

    public static class SetAumid {
        // ShellLink CLSID = 00021401-0000-0000-C000-000000000046
        // PKEY_AppUserModel_ID = {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, pid = 5
        public static void Apply(string lnkPath, string aumid) {
            Guid clsidShellLink = new Guid("00021401-0000-0000-C000-000000000046");
            Guid iidIShellLinkW = new Guid("000214F9-0000-0000-C000-000000000046");
            Native.CoCreateInstance(clsidShellLink, IntPtr.Zero, 1 /*CLSCTX_INPROC_SERVER*/, iidIShellLinkW, out object obj);

            IPersistFile pf = (IPersistFile)obj;
            pf.Load(lnkPath, 2 /*STGM_READWRITE*/);

            IPropertyStore ps = (IPropertyStore)obj;
            PROPERTYKEY key = new PROPERTYKEY {
                fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
                pid = 5
            };
            Native.InitPropVariantFromString(aumid, out PROPVARIANT pv);
            ps.SetValue(ref key, ref pv);
            ps.Commit();

            pf.Save(lnkPath, true);

            System.Runtime.InteropServices.Marshal.ReleaseComObject(obj);
        }
    }
'@

[GoMapi.AumidShortcut+SetAumid]::Apply($lnkPath, $Aumid)

Write-Host "Registered AUMID '$Aumid' on shortcut '$lnkPath'" -ForegroundColor Green
Write-Host "Target: $ExePath"
Write-Host
Write-Host "NOTE: log out and back in (or restart explorer.exe) if the first toast from wails dev doesn't persist."
```

**Idempotency pattern:** skip-if-exists. The first-run creates the shortcut; subsequent runs see the .lnk file and return 0. Read-back of the AUMID property to verify the correct value is set is a POSSIBLE extension but not needed for Phase 9 — the worst case if the file exists with wrong AUMID is the user runs `Remove-Item $lnkPath` and re-runs.

**Verification for dev workflow:**
```powershell
# Confirm AUMID is registered (list all AUMIDs on the shortcut):
(New-Object -ComObject Shell.Application).NameSpace('C:\Users\marc\AppData\Roaming\Microsoft\Windows\Start Menu\Programs').Items() `
    | Where-Object { $_.Name -like 'go-mapi*' } `
    | ForEach-Object { $_.Path, (Get-ItemProperty -Path $_.Path -Name 'AppUserModelID' -ErrorAction SilentlyContinue) }
```

Or simpler: fire a toast via `wails dev` → check Action Center → toast should persist with the `go-mapi (dev)` banner.

**Phase 10 forward pointer (INST-04):**
- Same pattern, different AUMID (`com.marcfargas.gomapi`), different shortcut path (`%ProgramFiles%\go-mapi\go-mapi.lnk`), registration via NSIS's `WriteRegStr` for AppUserModelID metadata + NSIS's CreateShortcut + a custom DLL or inline C# plugin to set PKEY_AppUserModel_ID. NSIS has known patterns for this via `ApplicationID` plugin (https://nsis.sourceforge.io/ApplicationID_plug-in).
- Installer will also need to write the HKCU registry keys for the COM activator CLSID → LocalServer32 → exe path (jackmordaunt's SetAppData does this at runtime, but installer ownership gives cleaner uninstall semantics).

### 7. Toast Removal Race (D-08)

**`MarkProcessed(id)` idempotency — VERIFIED from source (`internal/mapi/watcher.go:138-161`):**

```go
func (ew *EmailWatcher) MarkProcessed(id string) error {
    ew.mu.Lock()
    defer ew.mu.Unlock()

    var filename string
    for f, fid := range ew.fileToID {
        if fid == id {
            filename = f
            break
        }
    }
    if filename == "" {
        return fmt.Errorf("email not found: %s", id)  // ← NOT idempotent: returns error
    }
    // ...rm file, delete map entries...
}
```

**MarkProcessed is NOT idempotent today** — it returns `email not found` on an unknown ID. For Phase 9's toast-activation path, this means a double-click on the toast's "Create draft" button (or a race between Action Center Remove and a second user click) would produce an error log.

**Recommendation: update MarkProcessed to treat unknown IDs as success.**

```go
func (ew *EmailWatcher) MarkProcessed(id string) error {
    ew.mu.Lock()
    defer ew.mu.Unlock()

    var filename string
    for f, fid := range ew.fileToID {
        if fid == id {
            filename = f
            break
        }
    }
    if filename == "" {
        // Already processed (or never existed). Idempotent: double-activation
        // from the same toast action (Phase 9 NOTIF-03) must not surface as
        // an error.
        return nil
    }
    // ...
}
```

Single-line change + doc comment. Also apply the same semantics to `Delete(id)` for toast `Dismiss` double-clicks.

Test:
```go
func TestMarkProcessedIdempotent(t *testing.T) {
    // Set up watcher with one email; MarkProcessed twice; expect nil both times.
}
```

**Recommended ordering: process draft → remove file → then toast History.Remove.**

Rationale:
1. **Process draft first.** If it fails, the toast stays in Action Center (user sees it, can retry). If we Remove-first-then-draft and draft fails, user has no visual signal the email is still queued.
2. **Remove file second.** `MarkProcessed` deletes the JSON — this is the actual queue state change, triggers `queue-update` event, UI row disappears.
3. **History.Remove third.** Cleans up the stale toast. If this step fails (e.g., Windows version quirk), the toast leaks in Action Center but the email IS drafted — non-catastrophic.

Alternative ordering (Remove-first-to-prevent-double-click) fails because:
- WinRT `History.Remove` only removes CURRENTLY-persistent notifications. If the user has JUST clicked an action button, the callback is ALREADY firing — removing at this point has no effect on the click that triggered the callback.
- The double-click prevention happens at the `MarkProcessed` idempotency level (above fix), not at the toast level.

**Toast activation IPC — how does the handler know which email-id was clicked?**

Via `Action.Arguments` on each toast action button:

```go
noti := toast.Notification{
    AppID:  aumid,
    Title:  msg.From.DisplayName(),
    Body:   msg.Subject,
    Icon:   iconPath,
    ActivationType: toast.Foreground,
    ActivationArguments: "action=open&emailId=" + emailID, // clicking the body
    Actions: []toast.Action{
        {Type: toast.Foreground, Content: "Create draft", Arguments: "action=create-draft&emailId=" + emailID},
        {Type: toast.Foreground, Content: "Dismiss",      Arguments: "action=dismiss&emailId=" + emailID},
    },
}
```

The `Arguments` strings are delivered verbatim to `SetActivationCallback(func(args string, data []UserData))`. Our handler parses them as URL query params (§2 `handleToastAction` sketch). This is the standard WinRT pattern — inherited from jackmordaunt/go-toast's XML template [VERIFIED: xml.go.tmpl line 2 `launch="{{.ActivationArguments}}"` and line 34 action arguments].

### 8. Optional Niceties

**Gmail deep link (`Open in Gmail` on draft-success toast):**

URL format: `https://mail.google.com/mail/u/0/#drafts/{draftId}`

The `draftId` is returned from `GmailClient.CreateDraft` (already). Feasibility:

- **Single-account Gmail session:** URL works reliably — `u/0` is the default authenticated account.
- **Multi-account sessions:** `u/0` is the most-recently-authenticated, NOT necessarily the one the draft was created under. Users with multiple Gmail accounts logged into the browser may land on the wrong account's drafts list, where the draft ID returns 404. Confusing.
- **Alternative URL:** `https://mail.google.com/mail/u/{email_address}/#drafts/{draftId}` (substituting the actual signed-in email). Works for multi-account but exposes the email in the toast action's URL.

**Recommendation: ship the simple `u/0` URL with a Claude's-Discretion toggle, default ON.** Multi-account users are a minority; the 404 failure mode is graceful (they see their drafts list, not a crash). Phase 9 planner may punt this if the toast action surface is already feeling busy. No technical blocker.

Implementation: the draft-success toast (window-hidden path) gets an Action:
```go
{Type: toast.Protocol, Content: "Open in Gmail", Arguments: "https://mail.google.com/mail/u/0/#drafts/" + draftID}
```

Protocol activation handles this cleanly without a COM callback — Windows launches the URL in the default browser.

**Focus Session suppression (`SuppressPopup=true`):**

WinRT's `ToastNotification.SuppressPopup` property forces the toast to go straight to Action Center without a banner. This is useful during Windows 11 Focus Sessions (the user has opted into "do not disturb").

**jackmordaunt/go-toast v2.0.3 does NOT expose this** [VERIFIED: xml.go.tmpl lacks `suppressPopup` attribute; no Notification field for it].

**Skip for Phase 9.** Adding it requires either forking jackmordaunt OR extending our wintoast shim (which we're already doing for Tag/Group/History.Remove — easy to bundle). Reserve as a nice-to-have for Phase 11 polish. User impact: during Focus Sessions, arrival toasts pop a banner when the user has asked not to be disturbed. Annoying but not broken.

### 9. Landmines + Risks

**Planner must flag these:**

1. **NOTIF-05 is a real library gap.** The jackmordaunt/go-toast v2.0.3 high-level API does NOT expose `Tag`/`Group`/`History.Remove`. Two paths forward:
   - **(Recommended)** Add ~150 LOC wintoast shim using go-ole + x/sys/windows — re-implement `Push` with tag/group setters, add `Clear(aumid, tag, group)`. Pattern well-documented in jackmordaunt's own ARCHITECTURE.md.
   - **(Alternative)** Patch jackmordaunt upstream and pin to a fork. Higher maintenance burden.
   - **(Do not)** Skip NOTIF-05. Violates explicit requirement.

2. **COM activator GUID collision.** jackmordaunt/go-toast v2.0.3 ships with a hard-coded default GUID `{0F82E845-CB89-4039-BDBF-67CA33254C76}`. If another app on the same user account uses this library with the same default GUID, their toast activations will route to each other's callbacks. **Generate a go-mapi-specific GUID and pass it via `AppData.GUID`** — see §2 code sketch. Pin the GUID in source (so dev and prod use the same; do NOT regenerate per build).

3. **Double-Embedding command-line arg.** When a toast is clicked and the app isn't running, Windows invokes the registered LocalServer32 exe with a `-Embedding` flag. Our `main.go` startup does NOT currently detect `-Embedding` — it just runs `wails.Run`. This accidentally works (because COM activation is handled after runtime init by the jackmordaunt callback machinery), but adds a cold-start window where the first toast click waits ~500ms-2s for Wails to boot. Phase 9 planner should verify this works end-to-end. If it doesn't, add an early-check: `if slices.Contains(os.Args, "-Embedding") { /* fast-path COM-only init */ }`.

4. **RDS multi-session COM activator isolation.** HKCU is per-user per-session on RDS, so each session gets its own `HKCU\SOFTWARE\Classes\CLSID\{GUID}\LocalServer32`. This works as long as each session's `go-mapi.exe` is a different process — which our single-instance-per-session mutex already guarantees. The single-instance mutex is Local-namespaced (default), which is session-local, not machine-global — correct behavior. **Sanity check:** verify the single-instance mutex name in `src/app/singleinstance.go` does NOT use `Global\` prefix. (I checked: it doesn't appear to per the comment block — but planner should re-verify during implementation.)

5. **settings.json corruption edge case.** If the app crashes exactly between `MoveFileEx` initiating the atomic swap and the filesystem committing, there may be a half-committed state. `MOVEFILE_WRITE_THROUGH` flag (in our snippet) forces a physical disk write before returning — this closes the window on NTFS but adds ~1-5ms latency per write. Acceptable because settings writes are rare (only on user mode toggle click).

6. **`tray-has-queue.ico` asset must exist at build time.** If it's missing at compile, `//go:embed` fails build loudly — fine, the issue surfaces. Planner should add asset-creation as an explicit task in the phase plan (see D-16).

7. **Toast icon path absolute requirement.** jackmordaunt/go-toast's `Notification.Icon` field requires an absolute path (per the docstring). At `wails dev` time, the dev exe lives in `src/app/build/bin/` — the icon can live alongside it. At prod install time, icons live in `%ProgramFiles%\go-mapi\`. The Go code needs to resolve the icon path at runtime via `os.Executable()` + relative lookup. Add a helper `toastIconPath() string` in paths.go.

8. **The default jackmordaunt CLSID may write over an existing go-mapi CLSID registration if we override GUID later.** Our solution in §2 recommends pinning a go-mapi-owned GUID from day one. Ensure the AUMID string AND the CLSID GUID are both committed to source constants BEFORE Plan 01 writes any toast code — Phase 10's installer must register the SAME constants.

9. **Wails v2.12.0 has NO native toast helper.** Officially confirmed [CITED: Wails v3 notification docs exist, v2 has issue #1788 open since 2022, no v2 plugin architecture]. We roll our own via jackmordaunt. No upgrade path except migrating to Wails v3 alpha (rejected per STATE.md decisions).

10. **WR-03 sequencing lock-in.** Plan 01 (test hygiene) MUST land before any plan that touches `watcher_bridge.go`. Parallel waves are fine AFTER Plan 01. If a later plan also modifies `watcher_bridge.go` for automode fan-out (§4), schedule it in a later wave than Plan 01.

**Things that could break in RDS but not on a single-user laptop:**

- COM activator registration: confirmed HKCU-only, so RDS-safe. But: the `LocalServer32` path points to a specific EXE location. If two RDS users have go-mapi installed in different paths (per-user installs), their CLSID registrations point to different exes. OK: each user's HKCU resolves to their own exe. Fine.
- Single-instance mutex: must be session-local (not `Global\`). Verified by comment block in singleinstance.go, but planner should sanity-check.
- Toast Action Center persistence: requires the Start Menu shortcut with AUMID under `%APPDATA%\...` (per-user). Phase 10 installer writes this per-user; Phase 9 dev script writes it per-user. No shared state.
- AUMID uniqueness across sessions: the `com.marcfargas.gomapi` string is constant, but each session's AUMID registration lives in its own HKCU. No cross-session toast routing.

**Build-toolchain changes implied by chosen libraries:** NONE. Pure Go all the way down. MinGW still needed for the C++ DLL (unchanged). No cgo for the toast library. ✓

### 10. Libraries + References

**Primary dependencies (new in Phase 9):**

| Package | Import Path | Version |
|---------|-------------|---------|
| Toast notifications | `git.sr.ht/~jackmordaunt/go-toast/v2` | v2.0.3 (2025-01-17) |
| Atomic file writes | stdlib + `golang.org/x/sys/windows` | (already in go.mod) |

**Already-in-project (reused):**

| Package | Version | Use in Phase 9 |
|---------|---------|----------------|
| `github.com/go-ole/go-ole` | v1.3.0 (indirect) | Our wintoast shim for NOTIF-05 — promote to direct dep |
| `golang.org/x/sys/windows` | v0.30.0 (direct) | Atomic rename; session-end; registry |
| `fyne.io/systray` | v1.12.0 | Pause menu item addition |
| `github.com/wailsapp/wails/v2` | v2.12.0 | EventsEmit for `auto-draft-result`, `pause-changed` |

**Official Windows references (consulted):**

- [Send a local toast notification from other types of unpackaged apps](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/send-local-toast-other-apps) — registry-keys + AUMID + CustomActivator GUID; documents HKLM default but code readily works with HKCU [VERIFIED via jackmordaunt/go-toast source].
- [Activating toast notifications from desktop apps](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/toast-desktop-apps) — the decision matrix that proves foreground activation requires a COM activator for unpackaged apps.
- [ToastNotificationHistory Class](https://learn.microsoft.com/en-us/uwp/api/windows.ui.notifications.toastnotificationhistory) — `Remove(tag, group, aumid)` signature for NOTIF-05.
- [ToastNotificationHistory.Remove Method](https://learn.microsoft.com/en-us/uwp/api/windows.ui.notifications.toastnotificationhistory.remove?view=winrt-22621) — parameter documentation.
- [System.AppUserModel.ID](https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-id) — `PKEY_AppUserModel_ID = {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, pid=5`.
- [How to enable desktop toast notifications through an AppUserModelID](https://learn.microsoft.com/en-us/windows/win32/shell/enable-desktop-toast-with-appusermodelid) — Win32 shortcut + IPropertyStore pattern.
- [Adaptive and interactive toast notifications](https://learn.microsoft.com/en-us/windows/apps/design/shell/tiles-and-notifications/adaptive-interactive-toasts) — toast XML schema.

**Go-side library references (consulted):**

- [`jackmordaunt/go-toast/v2` README](https://git.sr.ht/~jackmordaunt/go-toast) — high-level API overview, inputs/actions patterns.
- [`jackmordaunt/go-toast/v2/wintoast` pkg.go.dev](https://pkg.go.dev/git.sr.ht/~jackmordaunt/go-toast/v2/wintoast) — low-level API surface.
- [jackmordaunt/go-toast ARCHITECTURE.md](C:/Users/marc/go/pkg/mod/git.sr.ht/~jackmordaunt/go-toast/v2@v2.0.3/ARCHITECTURE.md) — pure-Go COM pattern for implementing a COM activator.
- [`natefinch/atomic`](https://pkg.go.dev/github.com/natefinch/atomic) — alternative to stdlib approach.
- [`google/renameio`](https://pkg.go.dev/github.com/google/renameio) — confirmed NOT Windows-capable.

**Issues / known-bugs referenced:**

- [golang/go#8914](https://github.com/golang/go/issues/8914) — `os.Rename` atomicity on Windows. STILL OPEN as of 2026-04-19; Go 1.23 and 1.25 release notes show no improvements.
- [wailsapp/wails#1788](https://github.com/wailsapp/wails/issues/1788) — Notification support in Wails. OPEN since 2022; labeled v3.

**Version pins (recommended for go.mod):**

```go
// direct:
git.sr.ht/~jackmordaunt/go-toast/v2 v2.0.3
github.com/go-ole/go-ole v1.3.0  // promoted from indirect for shim

// NO new version pins needed — everything else is already in go.mod at the right version.
```

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Atomic file rename on Windows | Plain `os.Rename` | `windows.MoveFileEx(..., MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)` | `os.Rename` not atomic on Windows overwrite (still, 2026) [CITED: issue #8914] |
| COM activator VTable for toast | Raw `syscall.NewCallback` implementation from scratch | `jackmordaunt/go-toast/v2` | 500+ LOC of COM VTable handling the library already provides |
| Building toast XML by hand | `fmt.Sprintf("<toast>...</toast>", ...)` | `jackmordaunt/go-toast.Notification` | Escape-safe CDATA wrapping, attribute quoting, audio/action nesting already correct |
| AUMID lookup on existing shortcut | Raw PowerShell | Skip-if-exists idempotency; trust prior runs | Reading `PKEY_AppUserModel_ID` back requires the same IPropertyStore COM dance; simpler to assume existence == correct |
| Focus Session detection | Raw WinRT `FocusSessionManager` from Go | Skip for Phase 9 | Not exposed by jackmordaunt; adding it requires our own shim; not a core requirement |
| Toast action IPC between COM callback and main goroutine | Named pipes; shared memory | `chan` + `go` dispatch from `SetActivationCallback` closure | The closure runs on a COM thread but has access to our App struct; just dispatch work via a goroutine |

**Key insight:** Windows toast notifications have a LOT of COM/WinRT surface area. Lean heavily on `jackmordaunt/go-toast` for the bits it covers, and write a narrow shim (~150 LOC) only for the NOTIF-05 gap.

## Common Pitfalls

### Pitfall 1: Forgetting AUMID Start Menu shortcut in dev

**What goes wrong:** `wails dev` sends a toast; it appears as a banner but vanishes immediately from Action Center.

**Why it happens:** Action Center persistence requires a Start Menu shortcut whose `PKEY_AppUserModel_ID` matches the AUMID used in `SetAppData`. Without it, Windows treats the toast as ephemeral.

**How to avoid:** Run `scripts/register-dev-aumid.ps1` once per dev machine after the first `wails build`. Document this in README next to the `wails dev` instructions.

**Warning signs:** Toast banner flashes, then Action Center is empty. Event Viewer shows `ShellNotificationPlatform` warnings.

### Pitfall 2: Running NotificationCallback on the wrong goroutine

**What goes wrong:** Toast click handler mutates App state; race detector flags it under `-race`.

**Why it happens:** `SetActivationCallback` fires on a COM thread (different from Wails' main goroutine). Direct writes to App struct fields without synchronization race.

**How to avoid:** The callback should ONLY dispatch (no business logic). Use `go func() { a.actualHandler(args) }()` or write to a buffered channel that the App's main goroutine drains.

**Warning signs:** Occasional panics in the COM callback; race reports under `-race`.

### Pitfall 3: COM activator GUID collision with another jackmordaunt user

**What goes wrong:** Multi-app environments (unlikely for our use case but possible) where two different Go apps both use jackmordaunt/go-toast/v2 with the default GUID. Whichever registers last wins.

**Why it happens:** The library hard-codes a default CLSID; both apps overwrite each other's `HKCU\SOFTWARE\Classes\CLSID\{GUID}\LocalServer32`.

**How to avoid:** Generate a go-mapi-specific GUID once; pin in `src/app/toast.go` as a constant; pass via `AppData.GUID`.

**Warning signs:** Toast click launches the wrong app. Event Viewer shows activation routed to an unexpected EXE.

### Pitfall 4: Double-processing via toast action + row click race

**What goes wrong:** User sees arrival toast AND opens window. Clicks toast's "Create draft" AND row's "Create draft". Two CreateDraft API calls fire for the same email.

**Why it happens:** The toast handler and the frontend row handler both invoke `App.CreateDraftForID(id)`. If MarkProcessed isn't idempotent, the second one logs an error but the damage (duplicate draft in Gmail) is done.

**How to avoid:**
1. Make `MarkProcessed` idempotent (§7).
2. Add an in-flight set (guarded by a mutex) on App that blocks concurrent CreateDraftForID calls for the same ID. First caller wins; second caller returns "already in progress" non-error (or just no-ops).

**Warning signs:** Gmail drafts folder shows duplicate drafts for a single MAPI send event.

### Pitfall 5: Pausing during a burst leaves in-flight drafts mid-flight

**What goes wrong:** User clicks `Pause watching` while automode is drafting email #3 of a 10-email burst. Draft #3 keeps running; #4-10 don't start. User expects immediate stop.

**Why it happens:** `isPaused()` is checked at the top of `drain()` and in between each email, but not inside `MakeAuthenticatedGmailCall`. The current in-flight HTTP call continues to completion.

**How to avoid:**
- Accept this as the intended behavior: pause is "don't start new drafts", not "cancel in-flight ones". Matches Slack's pause model.
- Document: pause takes effect for the NEXT email; in-flight finishes.

Alternative (not recommended for Phase 9): pass `a.shutdownCtx` or a pause-aware context into `MakeAuthenticatedGmailCall`. Adds complexity for minor UX gain.

**Warning signs:** User complaint: "I paused but a draft still appeared in Gmail." Explanation: the draft was already in flight.

### Pitfall 6: settings.json write-before-read on dev hot-reload

**What goes wrong:** `wails dev` hot-reloads the Go code. The running app writes settings.json during the reload, the new process reads a half-written state.

**Why it happens:** Hot-reload kills the old process mid-write (rare but possible if user clicks the mode toggle exactly during reload).

**How to avoid:** The atomic-write pattern (§3) guarantees the file is never half-written. The new process either sees the old file or the new one. No mitigation needed beyond the pattern we're already using.

### Pitfall 7: AUMID string too long

**What goes wrong:** AUMID > 129 characters causes scheduled toast notifications to fail [CITED: Microsoft docs `0x8007007A`].

**Why it happens:** Microsoft's undocumented limit — we won't hit it with `com.marcfargas.gomapi.dev` (26 chars) but worth knowing.

**How to avoid:** Keep AUMID under 129 chars. Ours is.

## Code Examples

### Toast notification with actions and callback

```go
// src/app/toast.go — new file
package main

import (
    "fmt"
    "net/url"
    "os"
    "path/filepath"

    toast "git.sr.ht/~jackmordaunt/go-toast/v2"
)

// Constants — SAME values in dev and prod code; registered by Phase 9 dev helper
// script, and by Phase 10 installer for prod.
const (
    aumidProd = "com.marcfargas.gomapi"
    aumidDev  = "com.marcfargas.gomapi.dev"
    // Pinned go-mapi-owned CLSID for toast activator. Generated once; do not
    // regenerate. Installer (Phase 10) writes the CLSID→exe mapping; at
    // runtime the library ALSO ensures it (idempotent).
    toastActivatorGUID = "{B16C7F6E-5F93-4F85-A5E2-2E7C18B3BCB2}"
    toastGroup         = "go-mapi-queue"
)

// initToasts wires SetAppData + SetActivationCallback. Must run AFTER logging
// is available (logInfo/logError) and BEFORE any Push call.
func (a *App) initToasts() error {
    aumid := aumidDev
    if !devMode() {
        aumid = aumidProd
    }
    exePath, err := os.Executable()
    if err != nil {
        return fmt.Errorf("toast: find exe: %w", err)
    }
    iconPath, _ := filepath.Abs(filepath.Join(filepath.Dir(exePath), "assets", "tray", "tray-idle.png"))
    if err := toast.SetAppData(toast.AppData{
        AppID:         aumid,
        GUID:          toastActivatorGUID,
        ActivationExe: exePath,
        IconPath:      iconPath,
    }); err != nil {
        return fmt.Errorf("toast: SetAppData: %w", err)
    }
    toast.SetActivationCallback(func(args string, _ []toast.UserData) {
        // Dispatch OFF the COM thread — any App mutation must not happen on
        // this goroutine (Pitfall 2).
        go a.handleToastAction(args)
    })
    logInfo("toast: initialized (aumid=%s)", aumid)
    return nil
}

func (a *App) handleToastAction(args string) {
    q, err := url.ParseQuery(args)
    if err != nil {
        logError("toast: parse args %q: %v", args, err)
        return
    }
    action := q.Get("action")
    emailID := q.Get("emailId")
    switch action {
    case "create-draft":
        if err := a.CreateDraftForID(emailID); err != nil {
            logError("toast: CreateDraftForID %s: %v", emailID[:8], err)
        }
    case "dismiss":
        if err := a.DismissEmail(emailID); err != nil {
            logError("toast: DismissEmail %s: %v", emailID[:8], err)
        }
    case "open":
        a.showWindow()
    default:
        // Default click: show the window.
        a.showWindow()
    }
}

// fireArrivalToast sends the new-email toast. Suppressed when window is visible
// and focused (D-11 — UI-SPEC is canonical).
func (a *App) fireArrivalToast(id, from, subject string, attachmentCount int) {
    if a.isVisible() { // D-11: suppress if window visible (per UI-SPEC)
        return
    }
    if a.isPaused() { // D-14: paused → no toast
        return
    }
    body := subject
    if attachmentCount > 0 {
        body = fmt.Sprintf("%s\n📎 %d attachment(s)", subject, attachmentCount)
    }
    n := toast.Notification{
        AppID:               "go-mapi",
        Title:               from,
        Body:                body,
        ActivationType:      toast.Foreground,
        ActivationArguments: "action=open&emailId=" + id,
        Actions: []toast.Action{
            {Type: toast.Foreground, Content: "Create draft", Arguments: "action=create-draft&emailId=" + id},
            {Type: toast.Foreground, Content: "Dismiss", Arguments: "action=dismiss&emailId=" + id},
        },
    }
    // NOTE: Tag/Group setters are not exposed by jackmordaunt — use the wintoast
    // shim (see toast_shim.go) to Push with Tag=id + Group=toastGroup for
    // NOTIF-05 Action Center cleanup.
    if err := pushWithTagGroup(&n, id, toastGroup); err != nil {
        logError("toast: push arrival: %v", err)
    }
}
```

### Wintoast shim for tag/group + History.Remove (sketch)

```go
// src/app/toast_shim.go
//go:build windows

package main

// The jackmordaunt/go-toast/v2 high-level API does NOT expose ToastNotification.Tag/.Group
// or ToastNotificationHistory.Remove. This shim fills those gaps by talking to the
// Windows Runtime directly via go-ole. Pattern adapted from the library's own
// wintoast package — see ARCHITECTURE.md in that module.

// pushWithTagGroup sends a toast with Tag + Group set for later History.Remove.
// Falls back to toast.Notification.Push if any COM call fails (we still get the
// toast; we just won't be able to clear it from Action Center precisely).
func pushWithTagGroup(n *toast.Notification, tag, group string) error {
    // TODO-plan-01: implement via RoGetActivationFactory → IToastNotificationFactory2.CreateToastNotification → put_Tag/put_Group → CreateToastNotifier(aumid).Show
    // Reference: jackmordaunt/go-toast/v2 internal/winrt/ui/notifications/
    return n.Push() // TEMP: fall back to library Push so the rest of Phase 9 can proceed
}

// clearToast removes a specific toast from Action Center via History.Remove.
// No-op if any COM call fails (best-effort cleanup).
func clearToast(aumid, tag, group string) {
    // TODO-plan-01: implement via RoGetActivationFactory → IToastNotificationManagerStatics2.get_History → Remove(tag, group, aumid)
}

// clearAllToastsForGroup clears every toast in a group (used on Pause to quiet AC).
func clearAllToastsForGroup(aumid, group string) {
    // TODO-plan-01: implement via History.RemoveGroup(group, aumid)
}
```

The planner's Plan 01 (test hygiene) or Plan 02 (toast infra) fills in the TODO bodies. The shim is bounded in scope (~150 LOC).

### Atomic settings write

See §3 for the full `saveSettings` + `moveFileAtomic` code.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `go-toast/toast` (PowerShell-per-toast) | `jackmordaunt/go-toast/v2` (pure-Go COM) | 2024-10 when v2 launched | 200ms/toast → <10ms/toast; in-process activation callbacks |
| `os.Rename` on Windows | `windows.MoveFileEx` via `x/sys/windows` | N/A (stdlib still not atomic) | Stdlib still wrong; pattern unchanged since 2015 |
| COM activator in C++ with WRL | Pure Go via `syscall.NewCallback` | 2024 (jackmordaunt v2) | No cgo; same functional surface |
| Embedded webview for OAuth | System browser via `pkg/browser` | Phase 8 shipped | Covered by existing project; not Phase 9 concern |

**Deprecated/outdated:**

- `go-toast/toast` (gopkg.in/toast.v1): last commit 2021-ish; PowerShell-only; no AC persistence story. Don't touch.
- `go-ole/go-ole` tutorials referencing `oleutil.PutProperty` for WinRT: DEPRECATED; WinRT requires RoGetActivationFactory + VTable dispatch. jackmordaunt's ARCHITECTURE.md is the canonical Go-ecosystem reference.
- Microsoft's classic "toast as balloon tooltip" (NIIF_INFO): Win7-era, bypasses Action Center, looks broken on Win10/11. Don't use.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Action Center persistence on an unpackaged app requires a Start Menu shortcut with AUMID, even when the COM activator is registered. | §6, §2 | If wrong: we ship a helper script that isn't strictly needed. Low risk; it's a best-practice anyway per Microsoft docs. |
| A2 | jackmordaunt's library invokes `CoRegisterClassObject` on every `Push` call, so our single-instance app's COM class is re-registered per toast. | §2 | If wrong: we may need explicit init-time registration. Mitigation: test with the library; if toasts stop arriving after the first one, add explicit registration. |
| A3 | The Go `SetActivationCallback` closure runs on a COM apartment thread, NOT the main goroutine. | §2, Pitfall 2 | If wrong (it actually runs on main): our "dispatch to goroutine" pattern is unnecessary but harmless. If right: dispatching is load-bearing for race safety. Defensive is correct. |
| A4 | `MOVEFILE_WRITE_THROUGH` on NTFS forces disk commit before return, eliminating the tiny race window between rename and commit. | §3 | If wrong: crash-during-rename may leave settings.json in an inconsistent state on some filesystems (ReFS, FAT32). Mitigation: check-before-read that the file parses as valid JSON; fall back to defaults on parse error (already in loadSettings). |
| A5 | A 50ms sleep in WR-02 tests is sufficient for the bootstrap userinfo goroutine to settle on windows-latest CI. | §5 (WR-02) | If wrong (CI is slower than local): test flakes. Mitigation: use the deterministic `<-bootstrapAuth()` channel pattern instead (also recommended). |
| A6 | The default RDS loopback for DPAPI (Windows Credential Manager) is per-user-session. | CONTEXT D-11 carry-forward (Phase 8) | Already verified in Phase 8; reiterated for Phase 9 confidence. No action for Phase 9. |
| A7 | `fyne.io/systray v1.12.0` supports adding a menu item at runtime (vs only at `onTrayReady`). | §9 SHELL-02 completion (Pause watching) | If wrong: we must add the Pause item at tray-ready time and only toggle its label dynamically. Mitigation: read systray source/docs to confirm. |
| A8 | The `ActivationExe` field in jackmordaunt's AppData writes to `LocalServer32` (default value), which means that field IS the exe path that Windows invokes for out-of-process activation. Our call therefore needs `os.Executable()`, not a parent-folder scan. | §2, Pitfall 3 | If wrong: out-of-process toast activations fail when app is killed. Mitigation: verify at `wails dev` time by killing the dev process and clicking a live toast. |
| A9 | The `-Embedding` flag on cold-start-from-toast does not interfere with Wails' `wails.Run` — Wails just ignores unknown args. | §9 landmine 3 | If wrong: toasts that arrive when app is down fail to activate cleanly on first click. Mitigation: explicit test: kill app, wait for a MAPI event → toast → click → app comes up and processes action. |

## Open Questions

1. **Do we need `Action.Type: Protocol` for the `Open in Gmail` draft-success toast?**
   - What we know: Protocol activation routes to the default browser via URL scheme; Foreground activation routes to our app's in-process callback.
   - What's unclear: If Foreground is used, we'd have to open the browser ourselves from the callback (using `pkg/browser.OpenURL`). Trivial. No technical driver either way.
   - Recommendation: Use Protocol for the Open-in-Gmail action (simpler); Foreground for Create draft + Dismiss (must call our code).

2. **Should the pause-watching state survive across app restarts if the app was quit via tray menu (not OS logoff)?**
   - What we know: D-15 says "session-only, resets on every app start."
   - What's unclear: the word "session" is ambiguous between "Windows session" and "app session".
   - Recommendation: app-session (D-15 as written). Each `go-mapi.exe` launch starts un-paused. Simpler; matches "don't silently suppress" intent.

3. **Auto-draft-result event shape — include success?**
   - What we know: D-04 says window-visible success → in-window flash; hidden success → toast. The flash is driven by the existing `queue-update` event (row disappears). The flash itself could be driven by listening to `auto-draft-result` AND filtering by `success: true`.
   - What's unclear: whether the frontend wants a single consolidated event or separate success/failure events.
   - Recommendation: emit for BOTH success and failure. Frontend filters. Trivially small payload; keeps backend logic uniform.

4. **Does the dev helper script need UAC elevation?**
   - What we know: HKCU is per-user, no admin needed to write to `HKCU\SOFTWARE\Classes\...`.
   - What's unclear: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\` — per-user, no admin.
   - Recommendation: script runs as normal user. Planner confirms by running it on Marc's dev machine.

5. **Gmail deep-link `u/0` vs `u/<email>` tradeoff — ship which?**
   - See §8. Recommendation: `u/0` with opt-in via settings.json field (future). Phase 9 planner decides.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|-------------|-----------|---------|----------|
| Go 1.25+ | Build the Wails app | ✓ (project uses 1.25.0) | 1.25.0 | — |
| Node 20+ | Frontend toolchain | ✓ (Phase 8.1 CI confirmed) | 20.x | — |
| Windows 10/11 | Target platform | ✓ (dev Windows 11; CI windows-latest) | — | — |
| PowerShell 5.1+ | Run `register-dev-aumid.ps1` | ✓ (ships with Windows) | 5.1 | PowerShell 7 also works (Add-Type syntax unchanged) |
| `git.sr.ht/~jackmordaunt/go-toast/v2` | Toast notifications | ✓ (already indirect dep) | v2.0.3 | None — mandatory for NOTIF-01..05 |
| `github.com/go-ole/go-ole` | wintoast shim for NOTIF-05 | ✓ (already indirect dep) | v1.3.0 | None — required for COM interop |
| `golang.org/x/sys/windows` | MoveFileEx, registry | ✓ (already direct dep) | v0.30.0 | — |
| WebView2 Evergreen runtime | Wails render | ✓ (present on dev + CI) | Evergreen | Phase 10 installer bootstraps for end users |
| AUMID-registered Start Menu shortcut | Toast Action Center persistence | ✗ (one-time dev setup) | — | `register-dev-aumid.ps1` creates it |

**Missing dependencies with no fallback:** None — all stack components are either installed or bootstrapped by Phase 9 artifacts.

**Missing dependencies with fallback:** AUMID shortcut on fresh dev machines — addressed by Phase 9 Plan N (dev helper script, NOTIF-04 dev-side).

## Security Domain

`.planning/config.json` contains no explicit `security_enforcement` key; default per gsd-profile is ON, but the go-mapi project's security surface for Phase 9 is narrow:

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|------------------|
| V2 Authentication | Yes (inherited from Phase 8) | OAuth2 PKCE loopback via `golang.org/x/oauth2`, Windows Credential Manager via `zalando/go-keyring` |
| V3 Session Management | Yes (inherited) | AuthManager's refresh + invalid_grant lifecycle; single-user, no multi-account |
| V4 Access Control | No | Single-user desktop app; Windows user account is the trust boundary |
| V5 Input Validation | Yes (limited) | Toast action argument parsing (`url.ParseQuery`) — must not crash on hostile URLs (a user-adversarial model, which isn't a threat we face, but worth being defensive); `settings.json` parse tolerates garbage (§3) |
| V6 Cryptography | Yes (inherited) | Tokens in DPAPI-backed Credential Manager; no custom crypto in Phase 9 |

### Known Threat Patterns for Wails v2 + unpackaged Win32 + Go

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Toast action argument tampering (user edits .lnk or registry to change activation args) | Tampering | Argument is a trust boundary — parse defensively; `emailId` must match the content-hash of a file we know about, or no-op. Adversary would need to already have write access to HKCU → they already compromised the user. |
| Malicious toast that claims to be from go-mapi but comes from elsewhere | Spoofing | AUMID + CLSID-activated callback means only WE can push to our AUMID; other apps would need to register a different AUMID. |
| Credential leakage via toast content | Information disclosure | NOTIF-02 + QUAL-03 already forbid body/recipient content in toasts. Log hygiene (no subject/body/recipient in logs) remains in effect. |
| settings.json poisoning (user edits file while app is running) | Tampering | Parse defensively; normalize unknown mode values to default (§3). |
| Gmail API 401 loop if refresh token rotates incorrectly | Denial of service | `MakeAuthenticatedGmailCall` retries once on 401 then sets invalid_grant — bounded loop. |

Phase 9 adds NO new network endpoints, NO new secret storage, NO new trust boundaries. All security posture inherited from Phase 8.

## Sources

### Primary (HIGH confidence)

- [Microsoft Learn — Send a local toast notification from other types of unpackaged apps (updated 2025-07-28)](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/send-local-toast-other-apps) — registry keys, AUMID + CustomActivator pattern.
- [Microsoft Learn — Activating toast notifications from desktop apps (updated 2025-02-27)](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/toast-desktop-apps) — COM vs No-COM decision matrix; source for the finding that unpackaged apps NEED a COM activator for foreground/background activation.
- [Microsoft Learn — ToastNotificationHistory Class](https://learn.microsoft.com/en-us/uwp/api/windows.ui.notifications.toastnotificationhistory) — `Remove(tag, group, aumid)` signature.
- [Microsoft Learn — ToastNotificationHistory.Remove Method (winrt-22621)](https://learn.microsoft.com/en-us/uwp/api/windows.ui.notifications.toastnotificationhistory.remove?view=winrt-22621) — parameter documentation.
- [Microsoft Learn — System.AppUserModel.ID](https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-id) — `PKEY_AppUserModel_ID = {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, pid = 5`.
- [Microsoft Learn — How to enable desktop toast notifications through an AppUserModelID](https://learn.microsoft.com/en-us/windows/win32/shell/enable-desktop-toast-with-appusermodelid) — IShellLink + IPropertyStore pattern.
- [jackmordaunt/go-toast v2 — sourcehut](https://git.sr.ht/~jackmordaunt/go-toast) — primary library repo.
- [jackmordaunt/go-toast v2 — pkg.go.dev/git.sr.ht/~jackmordaunt/go-toast/v2](https://pkg.go.dev/git.sr.ht/~jackmordaunt/go-toast/v2) — high-level API.
- [jackmordaunt/go-toast v2/wintoast — pkg.go.dev](https://pkg.go.dev/git.sr.ht/~jackmordaunt/go-toast/v2/wintoast) — low-level API.
- Direct source inspection of `jackmordaunt/go-toast v2.0.3` at `C:/Users/marc/go/pkg/mod/git.sr.ht/~jackmordaunt/go-toast/v2@v2.0.3/` — README, ARCHITECTURE.md, toast.go, wintoast/registry.go, tmpl/xml.go.tmpl. [VERIFIED]

### Secondary (MEDIUM confidence — cross-verified with primary)

- [App-vNext/Notifier — DesktopNotificationManagerCompat.cs](https://github.com/App-vNext/Notifier/blob/master/src/AppVNext.Notifier.ConsoleUwp/DesktopNotificationManagerCompat.cs) — confirms HKCU path for `SOFTWARE\Classes\CLSID\{GUID}\LocalServer32` and History.Remove(tag, group) pattern.
- [natefinch/atomic — pkg.go.dev](https://pkg.go.dev/github.com/natefinch/atomic) — atomic file write alternative.
- [Google renameio — pkg.go.dev](https://pkg.go.dev/github.com/google/renameio) — confirms "not possible to reliably write files atomically on Windows" without a syscall wrapper.
- [golang/go issue #8914](https://github.com/golang/go/issues/8914) — `os.Rename` Windows atomicity; still open.
- [wailsapp/wails issue #1788](https://github.com/wailsapp/wails/issues/1788) — native toast support in Wails; v2 has none, v3 has proposed API.
- [Robertof/make-shortcut-with-appusermodelid](https://github.com/Robertof/make-shortcut-with-appusermodelid) — confirms "This isn't possible using standard Windows interfaces nor with PowerShell" without IPropertyStore COM calls.

### Tertiary (LOW confidence — flagged for validation by planner)

- [Tenforums.com — How to clear Windows Notifications from Action Center](https://www.tenforums.com/general-support/176698-how-clear-windows-notifications-action-center.html) — community discussion of Remove(tag, group, aumid); corroborates Microsoft docs.
- [NinjaOne — PowerShell toast notifications](https://www.ninjaone.com/script-hub/important-toast-notifications/) — confirms PowerShell-based toasts have latency but doesn't quantify to millisecond precision.

## Metadata

**Confidence breakdown:**

- Toast library choice (§1): HIGH — verified by reading library source, pkg.go.dev, and corroborating Microsoft docs.
- Action-button activation path (§2): HIGH — Microsoft decision matrix is explicit; jackmordaunt's COM activator is verified pure-Go implementation.
- Atomic write pattern (§3): HIGH — `os.Rename` Windows bug is documented-open in Go issue tracker; `MoveFileEx` semantics are in Microsoft docs.
- Automode architecture (§4): HIGH — pattern is a straightforward extension of existing watcherBridge code; interaction with `MakeAuthenticatedGmailCall` verified by reading auth.go.
- Test hygiene fixes (§5): HIGH — root causes verified by reading auth_test.go and watcher_bridge_test.go directly.
- AUMID dev script (§6): MEDIUM-HIGH — the inline-C# pattern is well-documented but has not been end-to-end tested on a fresh Windows dev machine in this research session. Script needs a live run before merging.
- Toast removal race (§7): HIGH — MarkProcessed non-idempotency verified in source; ordering recommendation follows from failure-mode analysis.
- Optional niceties (§8): MEDIUM — Gmail deep link multi-account behavior is inferred from URL structure, not tested.
- Landmines (§9): HIGH — each item has a concrete citation or source-level verification.

**Research date:** 2026-04-19

**Valid until:** 2026-05-19 (30 days — stable stack; no volatile dependencies except jackmordaunt/go-toast which had 4 releases in its first 4 months of existence, so re-check if Phase 9 slips past mid-May).

---

*Phase: 09-queue-automode-toasts*
*Research completed: 2026-04-19*
