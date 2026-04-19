# Phase 9: Queue, Automode + Toasts — Pattern Map

**Mapped:** 2026-04-19
**Files analyzed:** 24 new/modified
**Analogs found:** 22 / 24 (two new files — `toast.go`/shim and `register-dev-aumid.ps1` — have no close codebase analog; see §"No Analog Found")

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `src/app/app.go` (extended) | Wails binding host | request-response + event-driven | self (existing `GetQueue`, `SignOut` bindings) | exact |
| `src/app/automode.go` (new) | Go goroutine | event-driven (consumes wake chan) + request-response (Gmail) | `src/app/watcher_bridge.go` dispatcher | role-match |
| `src/app/automode_test.go` (new) | Go test | CRUD | `src/app/auth_test.go` `httptest.Server` scenarios (lines 634-805) | role-match |
| `src/app/settings.go` (new) | Go helper (file I/O) | file-I/O | `src/app/paths.go` + stdlib atomic-write pattern (RESEARCH §3) | role-match |
| `src/app/settings_test.go` (new) | Go test | file-I/O | `src/app/paths_test.go` (env-subtest + t.Setenv pattern) | role-match |
| `src/app/toast.go` (new) | Go helper | event-driven (COM callback) | **none in repo** — see §No Analog | N/A |
| `src/app/toast_windows.go` (new) | Go helper (build-tag) | COM WinRT | `src/app/credentials_check.go` + `credentials_check_bindings.go` build-tag split | partial (tag pattern only) |
| `src/app/toast_stub.go` (new, `//go:build !windows`) | Go helper (stub) | n/a | `src/app/credentials_check_bindings.go` | partial |
| `src/app/toast_test.go` (new, `//go:build windows`) | Go test | unit | `src/app/auth_keyring_windows_test.go` (tag + skip-if-env pattern) | role-match |
| `src/app/watcher_bridge.go` (modified) | Go bridge | event-driven | self (existing 1-slot pending channel) | exact |
| `src/app/watcher_bridge_test.go` (modified — WR-03) | Go test | event-driven | self — `TestDispatcherCoalesces` (lines 64-95) | exact |
| `src/app/auth_test.go` (modified — WR-01/WR-02) | Go test | request-response | self — `TestFetchUserInfoLocked_HappyPath` (lines 865-888) already sets `userinfoEndpointOverride` | exact |
| `src/app/tray.go` (modified) | Go tray integration | event-driven | self — `SetTrayError` / `SetTrayIdle` (lines 97-110) | exact |
| `src/app/assets/tray/tray-has-queue.ico` (new asset) | Icon asset | n/a | `src/app/assets/tray/tray-idle.ico`, `tray-error.ico` | exact |
| `src/app/frontend/src/lib/styles.css` (extended) | CSS tokens | n/a | self (existing `:root` + `.queue-row` rules) | exact |
| `src/app/frontend/src/App.svelte` (extended) | Svelte root | event-driven | self (existing `onMount` + `subscribeQueue` wiring) | exact |
| `src/app/frontend/src/lib/components/SignedInHeader.svelte` (extended) | Svelte component | props | self (existing header flex layout) | exact |
| `src/app/frontend/src/lib/components/QueueRow.svelte` (new) | Svelte component | props + event callbacks | `SignedInHeader.svelte` (onClick callback prop shape) + existing `.queue-row` grid in `styles.css` | role-match |
| `src/app/frontend/src/lib/components/QueueRow.test.ts` (new) | Vitest component test | unit | `SignedInHeader.test.ts` (props + fireEvent.click pattern) | exact |
| `src/app/frontend/src/lib/components/ModeToggle.svelte` (new) | Svelte component | props | `SignedInHeader.svelte` (simple prop-driven UI) | role-match |
| `src/app/frontend/src/lib/components/ModeToggle.test.ts` (new) | Vitest component test | unit | `SignedInHeader.test.ts` | exact |
| `src/app/frontend/src/lib/components/AutoDraftErrorBadge.svelte` (new) | Svelte component | props-only | `ReAuthBanner.svelte` (minimal single-purpose UI + `role` attribute) | role-match |
| `src/app/frontend/src/lib/components/AutoDraftErrorBadge.test.ts` (new) | Vitest component test | unit | `PreAuthModal.test.ts` | role-match |
| `src/app/frontend/src/lib/settings.ts` (new) | Svelte logic module | request-response (Wails binding wrappers) | `src/app/frontend/src/lib/auth.ts` | exact |
| `src/app/frontend/src/lib/settings.test.ts` (new) | Vitest unit test | unit | `src/app/frontend/src/lib/queue.test.ts` (vi.mock wails bindings pattern) | exact |
| `scripts/register-dev-aumid.ps1` (new) | PowerShell script | file-I/O (registry + shortcut) | **none** (scripts/dev-wails.ps1 is env-loader, not registry) | partial |

**Note on `mode.ts`:** CONTEXT.md mentions "new or inline in settings.ts". Recommend inline in `settings.ts` (one `AppSettings` type, one `getMode`/`saveMode` helper) — do NOT create a separate `mode.ts`. The single-module pattern matches `auth.ts` (combines status fetch + signIn + signOut + preauth-seen in one file).

---

## Pattern Assignments

### Go backend

#### `src/app/automode.go` (new — Go goroutine)

**Analog:** `src/app/watcher_bridge.go` (dispatch loop pattern) + `src/app/auth.go` `MakeAuthenticatedGmailCall`.

**Lifecycle pattern** — copy from `watcher_bridge.go` lines 15-46, 67-82:

```go
type watcherBridge struct {
    ctx       context.Context
    emitter   func(name string, data ...interface{})
    onError   func(err error)
    pending   chan struct{}
    done      chan struct{}
    closeOnce sync.Once
    getSnap   func() []mapi.EmailWithId
}

func (b *watcherBridge) dispatch() {
    for {
        select {
        case <-b.done:
            return
        case <-b.pending:
            b.emitter("queue-update")
        }
    }
}

// Close is idempotent (sync.Once guards the channel close).
func (b *watcherBridge) Close() {
    b.closeOnce.Do(func() { close(b.done) })
}
```

**Mirror in `automode.go`:**
- `sync.Once` + `chan struct{}` done-signal for idempotent stop
- Single goroutine reading from a 1-slot wake channel
- `select` loop with `<-m.done`, `<-m.wake`, `<-m.app.shutdownCtx.Done()`, plus a safety `<-tick.C`
- Field names: `done`, `closeOnce`, `wake` (read-only `<-chan struct{}`)

**Authenticated call pattern** — copy from `auth.go` lines 634-694:

```go
func (a *App) MakeAuthenticatedGmailCall(ctx context.Context, fn GmailCall) error {
    // Proactive refresh + 401 retry + invalid_grant classify + emitAuthChanged
    // Already handles: SetTrayError("sign-in expired"), clear keyring, return ErrInvalidGrant.
}
```

Automode `draftOne` wraps this — do NOT re-emit `auth-changed` or call `SetTrayError` from automode; those are already done inside `MakeAuthenticatedGmailCall`. Only emit `auto-draft-result` per outcome.

**Error classification** — copy the `errors.Is(err, ErrInvalidGrant)` check style from `auth.go` line 646, and map to the three UI categories per RESEARCH §4.

**Privacy-safe logging** — copy `logError` usage style from `auth.go` line 60: never include subject/body/recipient. Only log `e.Id[:8]` prefix + error category (see RESEARCH §4 line 655).

#### `src/app/settings.go` (new — Go file I/O)

**Analog:** `src/app/paths.go` (APPDATA path resolution) + the atomic-write snippet in RESEARCH §3 (lines 325-437).

**File-path pattern** — copy the env-precedence + `filepath.Join` style from `paths.go` lines 11-26.

**Atomic-write pattern** — use stdlib-only per RESEARCH §3 recommendation (no new dep):

```go
// RESEARCH §3 snippet (lines 381-432):
// 1. MkdirAll(dir, 0755)
// 2. json.Marshal
// 3. os.CreateTemp(dir, "settings-*.tmp")
// 4. tmp.Write / tmp.Sync / tmp.Close
// 5. windows.MoveFileEx(tmpW, dstW, MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)
// 6. defer os.Remove(tmpPath) for best-effort cleanup
```

**Error wrapping style** — copy from `auth.go` line 170: `fmt.Errorf("keyring load: %w", err)`. Lowercase error strings with a package-prefix (`"settings: mkdir: %w"`).

**No background-writer rule** — enforce single-writer invariant per RESEARCH §3. All `saveSettings` calls come from Wails bindings (UI-triggered). No goroutine may call it.

#### `src/app/settings_test.go` (new — Go test)

**Analog:** `src/app/paths_test.go` (lines 1-69) for subtests + `t.TempDir()` isolation; `src/app/auth_test.go` lines 102-125 for round-trip shape.

**Pattern:**
```go
func TestSaveLoadRoundTrip(t *testing.T) {
    dir := t.TempDir()
    t.Setenv("APPDATA", dir) // or whatever env var settingsPath() reads
    s := AppSettings{Mode: "auto-draft"}
    if err := saveSettings(s); err != nil { t.Fatal(err) }
    got := loadSettings()
    if got.Mode != s.Mode { t.Errorf(...) }
}
```

**Subtest pattern with env mutation** — copy from `paths_test.go` lines 22-68. Note the comment at line 16: "Subtests cannot use `t.Parallel` — they mutate process-wide env vars". Apply same rule to settings tests that mutate `APPDATA`.

**Corrupt-file coverage** — mirror RESEARCH §3 "Corrupt files are NOT moved aside" semantic: write garbage to `settings.json`, expect `loadSettings()` to return defaults (`Mode: "manual"`).

#### `src/app/app.go` (extended — new bindings)

**Analog:** self — existing `GetQueue()` at lines 170-177 and `SignOut()` at `auth.go` lines 712+.

**New bindings to add** (exported, so frontend `wailsjs/go/main/App.*` surfaces them):

```go
// Pattern: match GetQueue shape (line 172):
func (a *App) CreateDraftForID(id string) error { ... }
func (a *App) DismissEmail(id string) error     { ... }
func (a *App) GetSettings() AppSettings         { ... }
func (a *App) SaveSettings(s AppSettings) error { ... }
func (a *App) PauseWatching()                   { ... }
func (a *App) ResumeWatching()                  { ... }
func (a *App) GetPausedState() bool             { ... }
func (a *App) GetMode() string                  { ... }
func (a *App) SetMode(mode string) error        { ... }
```

**Struct-field additions** — mirror the existing `visibilityMu`/`visible` + `intentionalQuit atomic.Bool` pattern at `app.go` lines 25-31:

```go
// Pause state: session-only, sync.Mutex-guarded bool (D-15, RESEARCH §4).
pauseMu sync.Mutex
paused  bool

// Settings: RWMutex — UI reads frequently (tooltip helper), writes only on
// mode-toggle click.
settingsMu sync.RWMutex
settings   AppSettings

// Automode goroutine handle — started in startup, stopped in shutdown.
automode *automode
```

**Field comment style** — match `app.go` lines 25-31: one-line purpose + why the sync primitive was picked.

**Event emission** — copy from `app.go` line 75: `wruntime.EventsEmit(a.ctx, "queue-error", watcherErr.Error())`. Apply to new events:
- `auto-draft-result` (payload per UI-SPEC: `{emailId, success, errorCategory?}`)
- `pause-changed` (payload: `bool`) — per RESEARCH §4 line 709
- `settings-changed` optional (decide at plan time — frontend can re-read via `GetSettings` after `SaveSettings` resolves)

**No EventsEmit on watcher hot paths** — per PITFALLS §5 and CLAUDE.md. All automode event emits come from the automode goroutine, which is already off the watcher path.

#### `src/app/tray.go` (modified)

**Analog:** self — `SetTrayError` + `SetTrayIdle` (lines 97-110).

**Pattern to mirror:**

```go
//go:embed assets/tray/tray-idle.ico
var trayIdleIcon []byte

//go:embed assets/tray/tray-error.ico
var trayErrorIcon []byte

func (a *App) SetTrayError(msg string) {
    systray.SetIcon(trayErrorIcon)
    systray.SetTooltip("go-mapi — " + msg)
}
```

**Extend with:**
1. `//go:embed assets/tray/tray-has-queue.ico` → `trayHasQueueIcon []byte`
2. Consolidated tooltip helper per D-17:
   ```go
   // trayState aggregates everything the tooltip needs. Called whenever
   // mode, paused, authenticated, queue count, or watcher error changes.
   // Picks icon per D-16 priority + tooltip per D-17 format.
   func (a *App) refreshTrayVisual() { ... }
   ```
3. `Pause watching` / `Resume watching` menu item — mirror the existing `mShow`/`mQuit` construction at `tray.go` lines 46-67:
   ```go
   mPause := systray.AddMenuItem("Pause watching", "Silences toasts and auto-draft; queue still collecting")
   // in the goroutine loop:
   case <-mPause.ClickedCh:
       a.togglePause()
       if paused { mPause.SetTitle("Resume watching") } else { mPause.SetTitle("Pause watching") }
   ```

**LockOSThread invariant** — NEVER touch `systray.*` from a goroutine other than the one spawned at `tray.go` line 31-35 (`runtime.LockOSThread()` + `systray.Run`). `refreshTrayVisual` is called from `tray.go`'s own goroutine loop via a new signal channel, NOT from app.go or automode.go. (D-14 + RESEARCH §1 constraint reinforcement.)

#### `src/app/watcher_bridge.go` (modified — add automode wake + WR-03 fix)

**Analog:** self, existing 1-slot pending channel (lines 19-58).

**Pattern:** add a SECOND 1-slot channel called `automodeWake` (parallel to `pending`), also fed from `OnQueueChanged` with the same non-blocking-send-drop-if-full semantics. RESEARCH §4 lines 482-498 specifies the layout:

```go
type watcherBridge struct {
    // ... existing fields ...
    pending      chan struct{}
    automodeWake chan struct{}
    // ...
}

func (b *watcherBridge) OnQueueChanged(_ []mapi.EmailWithId) {
    select { case b.pending <- struct{}{}: default: }
    select { case b.automodeWake <- struct{}{}: default: }
}
```

**Why NOT a fan-out goroutine:** decoupling per RESEARCH §4 — UI `queue-update` must not be blocked by Gmail API latency. Two independent 1-slot coalesce signals.

**WR-03 fix** — update `TestDispatcherCoalesces` assertion at `watcher_bridge_test.go` line 92 per RESEARCH §Summary + §D-18:

```go
// Current (line 92-94):
if count != 1 {
    t.Errorf("dispatcher should emit exactly 1 time for a blocked burst, got %d", count)
}
// Fix: loosen to count >= 1 && count <= len(burst)+1 and document WHY.
if count < 1 || count > 50 {  // len(burst) == 50 in current test (1 initial + 49 loop)
    t.Errorf("dispatcher should emit at least 1 and at most %d times, got %d", 50, count)
}
```

Add a block comment above the test explaining: the 1-slot pending channel is a signal-only primitive; under burst it guarantees "at least one emit, at most one per OnQueueChanged call" — not exactly one.

#### `src/app/auth_test.go` (modified — WR-01 + WR-02)

**WR-01 fix** — remove `t.Parallel()` from `TestAuthCodeURLHasPKCE` at line 181. The test mutates package-level `oauthClientID` / `oauthClientSecret` (lines 183-185). The `t.Cleanup` restores them, but parallel tests can observe the mutation. Leave the `oauthClientID = ...` block as-is; just delete line 181.

Reference: the pattern for intentionally-non-parallel tests is `TestWatcherDir_EnvPrecedence` in `paths_test.go` (comment at line 16: "Subtests cannot use `t.Parallel — they mutate process-wide env vars").

**WR-02 fix** — `TestBootstrapAuthSignedInPath` (line 607) and `TestBootstrapAuth_TransientErrorKeepsTokens` (line 810) both rely on the real Google userinfo endpoint because bootstrap triggers an async userinfo fetch. The `userinfoEndpointOverride` variable already exists (`auth.go` line 69) and is exercised by `TestFetchUserInfoLocked_HappyPath` at lines 874-875:

```go
// Pattern to copy (auth_test.go lines 866-876):
srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    _, _ = w.Write([]byte(`{"email":"marc@example.com","name":"Marc"}`))
}))
defer srv.Close()
userinfoEndpointOverride = srv.URL
t.Cleanup(func() { userinfoEndpointOverride = "" })
```

Add the same stub at the top of `TestBootstrapAuthSignedInPath` and `TestBootstrapAuth_TransientErrorKeepsTokens`. The stub can return a minimal 200 payload (or 503 for the transient case if `bootstrapAuth` even calls userinfo on a failed refresh — verify in code before writing).

#### `src/app/automode_test.go` (new — Go test)

**Analog:** `src/app/auth_test.go` lines 634-805 (`TestRefresh_*`, `TestBootstrapAuth_*`) — canonical httptest.Server + endpoint-override pattern for Gmail/OAuth mocked paths.

**Key scenarios** (per RESEARCH §4 landmines):
- Success path: stub token endpoint (for potential refresh) + stub Gmail endpoint → expect `auto-draft-result{success:true}` emitted; expect `MarkProcessed` called (use a fake watcher).
- `invalid_grant` path: token endpoint returns 400 `invalid_grant` → expect `errorCategory:"signed-out"` emitted ONCE; expect drain halts (no further emits for remaining queued items).
- Network error: Gmail endpoint returns a transport error (close srv mid-test or use a timeout context) → expect `errorCategory:"network"`.
- Gmail 5xx: stub returns 500 → expect `errorCategory:"gmail"`.
- Pause respect: set `app.paused = true`, trigger wake → expect zero emits.
- Mode respect: set mode to `"manual"`, trigger wake → expect zero emits.

**Emitter injection** — the emitter in automode is currently `wruntime.EventsEmit(a.ctx, ...)` per RESEARCH §4 line 656. That pattern can't be called from unit tests (no Wails runtime). Recommend: mirror `newWatcherBridgeWithEmitter` pattern at `watcher_bridge.go` line 35 — accept an injectable `emitter func(string, ...interface{})` so `newAutomode` (or a test constructor) can capture emitted events.

**Fake watcher** — mirror `fakeKeyringStore` (auth_test.go lines 22-64): in-memory struct that implements `Snapshot()` / `MarkProcessed(id)` / `Delete(id)` for tests.

#### `src/app/toast.go` / `toast_windows.go` / `toast_stub.go` (new)

**Analog:** NONE in repo — this is genuinely new territory. See §No Analog Found.

**Build-tag split pattern** — copy the shape (not content) from `src/app/credentials_check.go` (no tag) vs `src/app/credentials_check_bindings.go` (`//go:build bindings`):

- `toast.go` — shared interface + constructor delegation, no tags
- `toast_windows.go` — `//go:build windows && !bindings` (real COM/WinRT calls; no bindings tag because wailsbindings.exe introspects this file without a Windows toolchain available. Planner: verify whether CI runs wailsbindings.exe on Windows — if yes, drop the `!bindings` guard)
- `toast_stub.go` — `//go:build !windows` (no-op stubs for cross-platform compile)

**go-ole + x/sys/windows shim** — ~150 LOC per RESEARCH §1 "Library gaps" table. Reference the patterns documented in jackmordaunt/go-toast/v2's ARCHITECTURE.md. Must expose at minimum:
```go
func Push(aumid string, n Notification) error       // wraps library + sets Tag/Group
func ClearToast(aumid, tag, group string) error     // calls History.Remove via WinRT
```

**Error wrapping** — match project convention (lowercase + `%w`): `fmt.Errorf("toast: get toastmanager factory: %w", err)`.

**Activation callback** — copy RESEARCH §2 snippet (lines 250-289):
```go
toast.SetActivationCallback(func(args string, data []toast.UserData) {
    // COM-thread callback — dispatch to app goroutine via channel, DO NOT do work here
    a.handleToastAction(args)
})
```

#### `src/app/toast_test.go` (new, Windows-only)

**Analog:** `src/app/auth_keyring_windows_test.go` — already uses `//go:build windows` + "skip if not on Windows / CI env var missing" guard pattern. Copy the file header:

```go
//go:build windows
// +build windows

package main

import (
    "os"
    "testing"
)

func TestToastRegistration_Integration(t *testing.T) {
    if os.Getenv("CI") == "" && os.Getenv("GOMAPI_RUN_WINDOWS_TESTS") == "" {
        t.Skip("integration test; set GOMAPI_RUN_WINDOWS_TESTS=1 to run locally")
    }
    // ...
}
```

Confirm actual skip-guard from `auth_keyring_windows_test.go` before writing (this pattern is standard but the env var name should be copied verbatim).

### Frontend (Svelte 5 + Vitest)

#### `src/app/frontend/src/lib/components/QueueRow.svelte` (new)

**Analog:** `SignedInHeader.svelte` (prop-with-callback shape) + existing `.queue-row` grid in `styles.css` lines 22-27.

**Props shape** — copy from `SignedInHeader.svelte` line 2:

```svelte
<script lang="ts">
  import type { EmailWithId } from '../queue';
  let {
    item,
    state = 'idle',
    authenticated = true,
    errorCategory,
    onCreateDraft,
    onDismiss,
  }: {
    item: EmailWithId;
    state?: 'idle' | 'in-flight' | 'drafted-flash' | 'error';
    authenticated?: boolean;
    errorCategory?: 'signed-out' | 'network' | 'gmail';
    onCreateDraft: (id: string) => void;
    onDismiss: (id: string) => void;
  } = $props();
</script>
```

**$derived usage** — copy from `SignedInHeader.svelte` line 3 (`const displayName = $derived(email || name || 'your Google account')`). Apply to sender/subject/attachment-count display + `disabled-unauthenticated` state.

**Styles + tokens** — import `../styles.css` (actually already inherited via `App.svelte` import per UI-SPEC "existing token file" note). Use scoped `<style>` for component-local rules. All colors MUST come from `var(--c-*)` tokens — see UI-SPEC §Color.

**Accessibility** — `tabindex="0"`, `type="button"` on action buttons, `title="Sign in first"` tooltip when unauthenticated. Per UI-SPEC §Accessibility Baseline + Phase 8 D-07 carried forward.

#### `src/app/frontend/src/lib/components/ModeToggle.svelte` (new)

**Analog:** `SignedInHeader.svelte` (minimal component + prop-callback shape).

**Props:**
```svelte
<script lang="ts">
  let { mode, onModeChange }: {
    mode: 'manual' | 'auto-draft';
    onModeChange: (next: 'manual' | 'auto-draft') => void;
  } = $props();
</script>
```

**Segmented-control markup** — two `<button type="button">` elements per UI-SPEC §Mode Toggle (lines 182-201). Use `aria-pressed={mode === 'manual'}` + `aria-pressed={mode === 'auto-draft'}` per UI-SPEC §Accessibility. Wrapper `div` gets `role="group" aria-label="Draft mode"`.

#### `src/app/frontend/src/lib/components/AutoDraftErrorBadge.svelte` (new)

**Analog:** `ReAuthBanner.svelte` — minimal single-purpose component with `role` attribute and inline `<style>` block.

**Props:**
```svelte
<script lang="ts">
  let { category }: {
    category: 'signed-out' | 'network' | 'gmail';
  } = $props();
  const label = $derived({
    'signed-out': 'Signed out',
    'network': 'Network error',
    'gmail': 'Gmail error',
  }[category]);
</script>
<span class="badge" role="status" aria-label={`Auto-draft failed: ${label}`} title={label}>!</span>
```

Dimensions + colors per UI-SPEC §AutoDraft Error Badge (lines 172-178): 20×20 circle, `var(--c-destructive)` bg, `!` glyph at 11px semibold.

#### `src/app/frontend/src/lib/components/{QueueRow,ModeToggle,AutoDraftErrorBadge}.test.ts` (new)

**Analog:** `SignedInHeader.test.ts` (lines 1-40) — vi.fn() props + render() + fireEvent.click + getByText/getByRole assertions.

**Pattern to mirror:**

```typescript
import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/svelte';
import QueueRow from './QueueRow.svelte';

describe('QueueRow', () => {
  it('renders sender with fallback when missing', () => { ... });
  it('hides attachment count when count === 0 (D-02)', () => { ... });
  it('disables action buttons when authenticated=false', () => { ... });
  it('calls onCreateDraft with item.id when button clicked', async () => {
    const onCreateDraft = vi.fn();
    const { getByRole } = render(QueueRow, { props: { item: {...}, onCreateDraft, onDismiss: vi.fn() } });
    await fireEvent.click(getByRole('button', { name: /create draft/i }));
    expect(onCreateDraft).toHaveBeenCalledWith('abc');
  });
  it('shows AutoDraftErrorBadge when state==="error"', () => { ... });
});
```

For `ModeToggle.test.ts`: copy the `aria-pressed` assertion pattern from jsdom-compatible queries (`getByRole('button', {name: /manual/i, pressed: true})`).

#### `src/app/frontend/src/lib/settings.ts` (new)

**Analog:** `src/app/frontend/src/lib/auth.ts` (lines 1-47) — canonical pattern for wails-binding wrappers + typed re-exports + `$state`-free module functions.

**Pattern to mirror:**
```typescript
import { GetSettings, SaveSettings, GetMode, SetMode, PauseWatching, ResumeWatching, GetPausedState } from '../../wailsjs/go/main/App';
import type { main } from '../../wailsjs/go/models';

export type AppSettings = main.AppSettings;
export type Mode = 'manual' | 'auto-draft';

export async function fetchSettings(): Promise<AppSettings> {
  return await GetSettings();
}
export async function saveSettings(s: AppSettings): Promise<void> {
  await SaveSettings(s);
}
// + setMode, getMode, pauseWatching, resumeWatching, getPausedState
```

**Event subscription** — mirror `auth.ts` line 36-38 `subscribeAuth` shape if `auto-draft-result` / `pause-changed` need frontend-wide subscriptions:
```typescript
export function subscribeAutoDraftResult(cb: (r: AutoDraftResult) => void): () => void {
  return EventsOn('auto-draft-result', (r: AutoDraftResult) => cb(r));
}
```

#### `src/app/frontend/src/lib/settings.test.ts` (new)

**Analog:** `src/app/frontend/src/lib/queue.test.ts` (lines 1-103) — vi.mock of `'../../wailsjs/go/main/App'` + `'../../wailsjs/runtime/runtime'` at top of file; mocked function return values via `(fn as unknown as ReturnType<typeof vi.fn>).mockResolvedValue(...)`.

**Pattern:**
```typescript
vi.mock('../../wailsjs/go/main/App', () => ({
  GetSettings: vi.fn(),
  SaveSettings: vi.fn(),
  // ...
}));
vi.mock('../../wailsjs/runtime/runtime', () => ({
  EventsOn: vi.fn(() => () => {}),
}));
```

#### `src/app/frontend/src/App.svelte` (extended)

**Analog:** self — existing `onMount` Promise.all pattern (lines 31-56).

**Extend by:**
1. Add `mode = $state<Mode>('manual')`, `paused = $state(false)`, `autoDraftErrors = $state<Map<string, ErrorCategory>>(new Map())`.
2. Mirror the existing `Promise.all([fetchAuthStatus(), fetchQueue()...])` at line 33 to also `fetchSettings()`.
3. Add `unsubAutoDraft = EventsOn('auto-draft-result', ...)` parallel to line 45 `unsubQueueError = EventsOn('queue-error', ...)`. Cleanup in `onDestroy` at line 59.
4. Replace the inline `<li class="queue-row">` at line 127-135 with `<QueueRow item={item} state={...} authenticated={auth.authenticated} errorCategory={...} onCreateDraft={...} onDismiss={...} />`.
5. Mount `<ModeToggle>` inside `<SignedInHeader>` via prop extension (see below).

#### `src/app/frontend/src/lib/components/SignedInHeader.svelte` (extended)

**Analog:** self (lines 1-23).

**Extend props** to accept mode + onModeChange + (optional) paused + onPauseToggle — mirror the existing `email, name, onSignOut` destructuring on line 2:

```svelte
<script lang="ts">
  import ModeToggle from './ModeToggle.svelte';
  let {
    email, name, onSignOut,
    mode, onModeChange,
  }: {
    email: string; name: string; onSignOut: () => void;
    mode: 'manual' | 'auto-draft';
    onModeChange: (m: 'manual' | 'auto-draft') => void;
  } = $props();
</script>
```

**Layout** per UI-SPEC §Signed-In Header (lines 202-213): three flex zones, `align-items: center`, `justify-content: space-between`. Add the `ModeToggle` in the middle slot.

#### `src/app/frontend/src/lib/styles.css` (extended)

**Analog:** self (lines 1-28).

**Extensions** — append to `:root` block per UI-SPEC §"Tokens to Add":

```css
--space-xl: 32px;
--space-2xl: 48px;
--space-btn-x: 12px;
--c-error-bg: #FEF0EE;
--c-success-flash: #E6F4EA;
--c-success-text: #188038;
```

Keep the existing `.queue-row` grid (already `[sender 1fr] [subject 2fr] [actions auto]`). Add `.queue-row` state modifier classes (`.queue-row--error`, `.queue-row--flash`, `.queue-row--inflight`) — scoped styles inside `QueueRow.svelte` are also acceptable per UI-SPEC intro.

### Asset

#### `src/app/assets/tray/tray-has-queue.ico` (new asset)

**Analog:** `src/app/assets/tray/tray-idle.ico` + `tray-error.ico` (existing, embedded at `tray.go` lines 11-15).

**Pattern:**
1. Design per UI-SPEC §Tray Icon Variants (lines 346-360): same base glyph as idle + amber `#E8A600` dot bottom-right. Both 16×16 and 32×32 frames in the `.ico` (ICO format supports multiple frames).
2. Drop into `src/app/assets/tray/` (sibling to existing icons).
3. Add `//go:embed assets/tray/tray-has-queue.ico` directive in `tray.go` (see Tray pattern above).
4. Commit source artwork under `src/app/assets/tray/sources/` if the existing directory convention holds (verify — `ls` showed a `sources` subdir).

### Script

#### `scripts/register-dev-aumid.ps1` (new)

**Analog:** `scripts/dev-wails.ps1` (shape + error-handling style only — not registry patterns).

**Shape to mirror** (`dev-wails.ps1` lines 1-12):
```powershell
#!/usr/bin/env pwsh
# <purpose line>
$ErrorActionPreference = 'Stop'
# ... validate inputs ...
# ... do work ...
```

**Inline C# via `Add-Type`** — per RESEARCH §6 (read the research section before writing; this is the standard IShellLink + IPropertyStore + PKEY_AppUserModelID pattern on Windows). The research section specifies idempotent (skip-if-exists) + HKCU Start Menu path + AUMID `com.marcfargas.gomapi.dev`.

**No analog in repo for registry/COM work.** This is genuinely new territory for this codebase.

---

## Shared Patterns

### Go — Event emission via Wails runtime

**Source:** `src/app/app.go` line 75 + `src/app/auth.go` line 701 + `src/app/watcher_bridge.go` line 29.

**Apply to:** all new Go event emits (`auto-draft-result`, `pause-changed`, optional `settings-changed`).

**Pattern:**
```go
wruntime.EventsEmit(a.ctx, "event-name", payload)
```

**Rules (PITFALLS §5 + CLAUDE.md):**
- NEVER emit from watcher hot paths — route through the 1-slot pending channel or automodeWake channel.
- NEVER emit before `a.ctx` is set (startup line 42). `emitAuthChanged` at `auth.go` line 697-702 guards nil ctx — copy that guard on any new emitter if called pre-startup.
- In tests, inject an emitter function (see `newWatcherBridgeWithEmitter` at `watcher_bridge.go` line 35) — do NOT call wruntime.EventsEmit without a live Wails ctx.

### Go — Lifecycle (done channel + sync.Once)

**Source:** `src/app/watcher_bridge.go` lines 19-82.

**Apply to:** new `automode` goroutine (`src/app/automode.go`) and any future long-lived goroutine.

```go
type automode struct {
    done      chan struct{}
    closeOnce sync.Once
}
func (m *automode) stop() {
    m.closeOnce.Do(func() { close(m.done) })
}
```

**Idempotency test pattern** — copy `TestBridgeCloseIdempotent` at `watcher_bridge_test.go` lines 122-135 (calls `Close()` twice with defer-recover, expects no panic).

### Go — httptest-stubbed auth tests

**Source:** `src/app/auth_test.go` lines 634-665 (`TestRefresh_InvalidClient_ReturnsError`).

**Apply to:** `automode_test.go` (failure-path scenarios), WR-02 fix in `auth_test.go`.

```go
srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(400)
    _, _ = w.Write([]byte(`{"error":"invalid_client"}`))
}))
defer srv.Close()
tokenEndpointOverride = srv.URL
t.Cleanup(func() { tokenEndpointOverride = "" })
```

Mirror the same shape for `userinfoEndpointOverride` (WR-02). For automode Gmail-stub tests: create an injectable `GmailClient` factory on `App` or inject via the existing endpoint-override seam in `internal/mapi/gmail.go` (confirm its override mechanism — research says the endpoint base is injectable).

### Go — In-memory fakes for interfaces

**Source:** `src/app/auth_test.go` lines 19-64 (`fakeKeyringStore`).

**Apply to:** fake watcher for `automode_test.go` (implements `Snapshot()`, `MarkProcessed()`, `Delete()`).

Mirror the `sync.Mutex`-guarded map pattern + constructor (`newFakeKeyringStore` at line 31).

### Go — Privacy-safe logging

**Source:** `src/app/app.go` lines 68-70 comment: `// T-07-22: log infrastructure event only, not email content.` + QUAL-03 in PROJECT.md.

**Apply to:** all new Go code paths. Automode failure log must use `e.Id[:8]` prefix + `category` only (RESEARCH §4 line 655). Never log subject, body, recipient.

### Svelte — Runes + prop-callback components

**Source:** `SignedInHeader.svelte` lines 1-4; `ReAuthBanner.svelte` lines 1-3.

**Apply to:** `QueueRow.svelte`, `ModeToggle.svelte`, `AutoDraftErrorBadge.svelte`.

Pattern: `let { <props> }: { <types> } = $props();` + `$derived(...)` for computed values + `onclick={callback}` event wiring. No legacy `export let`, no `$:` reactive statements, no stores (per CLAUDE.md Svelte 5 runes directive).

### Svelte — Component test scaffolding

**Source:** `SignedInHeader.test.ts` (lines 1-40).

**Apply to:** all new `*.test.ts` files under `lib/components/`.

```typescript
import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/svelte';
import Component from './Component.svelte';

describe('Component', () => {
  it('<behavior>', async () => {
    const onX = vi.fn();
    const { getByRole /* or getByText */ } = render(Component, { props: { /*...*/, onX } });
    await fireEvent.click(getByRole('button', { name: /label/i }));
    expect(onX).toHaveBeenCalledOnce();
  });
});
```

### Svelte — Wails-binding module tests (mock pattern)

**Source:** `src/app/frontend/src/lib/queue.test.ts` lines 8-17.

**Apply to:** `settings.test.ts` (and any future wails-binding wrapper test).

```typescript
vi.mock('../../wailsjs/go/main/App', () => ({
  GetXxx: vi.fn(),
  SaveXxx: vi.fn(),
}));
vi.mock('../../wailsjs/runtime/runtime', () => ({
  EventsOn: vi.fn(() => () => {}),
}));
```

### CSS — Token usage (no hard-coded colors)

**Source:** `src/app/frontend/src/lib/styles.css` lines 1-14 (`:root` declarations) + UI-SPEC §Color.

**Apply to:** every new component `<style>` block + every new rule in `styles.css`. All colors and spacings from `var(--c-*)` / `var(--space-*)`. Exception: the literal `#188038` success-text color is getting added as `--c-success-text` in this phase (see UI-SPEC tokens-to-add block).

**Anti-pattern to avoid:** `ReAuthBanner.svelte` currently hard-codes `#d93025` (line 12). UI-SPEC says Phase 9 "should align it to `var(--c-destructive)`" — this is a one-line change, fold into the styles plan.

---

## No Analog Found

Files with no close match in the codebase (planner should use RESEARCH.md snippets + Microsoft docs as primary source):

| File | Role | Reason |
|---|---|---|
| `src/app/toast.go` + `toast_windows.go` | COM/WinRT Go helper | No prior COM / WinRT / go-ole usage in this codebase. RESEARCH §1 + §2 + the jackmordaunt/go-toast/v2 source are the only references. |
| `scripts/register-dev-aumid.ps1` | PowerShell + inline C# (IShellLink/IPropertyStore) | No existing Windows-shortcut/registry script in this repo. `dev-wails.ps1` is an env-loader, not a registry tool. RESEARCH §6 is the reference. |

**Planner guidance for no-analog files:**
- `toast.go` + shim — land as a dedicated plan with a focused test strategy; expect a longer review cycle because there's no established pattern to lean on.
- `register-dev-aumid.ps1` — keep scope to dev-machine registration only. Prod registration (Phase 10 INST-04) owns the installer-side version. Dev script must be idempotent and skip-if-exists (RESEARCH §6 emphasizes this).

---

## Metadata

**Analog search scope:**
- `src/app/` — Go backend + embedded assets
- `src/app/frontend/src/lib/` — Svelte components + logic modules
- `scripts/` — PowerShell helpers
- `internal/mapi/` — shared core (not modified in Phase 9; referenced as consumer target)
- `.planning/phases/09-queue-automode-toasts/` — CONTEXT, RESEARCH, UI-SPEC

**Files scanned:** ~40 Go / Svelte / TS / CSS files across `src/app/` and `internal/mapi/`.

**Pattern extraction date:** 2026-04-19.

---

## Summary for Planner

1. **Plan sequencing:** put WR-01/WR-02/WR-03 test-hygiene fixes as Plan 01 (per D-18 + CONTEXT.md §Specifics §WR-03 sequencing) so all subsequent plans run against green CI.
2. **Settings + mode toggle + bindings** can be a self-contained early plan (no automode coupling).
3. **watcher_bridge.go fan-out** should land before `automode.go` (the second wake channel is the seam).
4. **`toast.go` shim + `register-dev-aumid.ps1`** are the two plans with genuinely new territory — schedule them with extra review buffer.
5. **`tray-has-queue.ico` asset creation** is a real task (not a trivial add). Can parallel with automode work.
6. **Frontend components** can land in parallel plans once `settings.ts` + new bindings exist.
7. **All new exported Go bindings** require a `wails generate module` step (or equivalent) so `wailsjs/go/main/App.ts` surfaces them to the frontend. Verify whether Phase 7/8 automated this or if it's a manual `cd src/app && wails generate module` invocation — check `package.json` scripts before planning.
