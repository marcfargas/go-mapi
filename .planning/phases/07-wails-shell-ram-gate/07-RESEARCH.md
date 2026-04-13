# Phase 7: Wails Shell + RAM Gate - Research

**Researched:** 2026-04-13
**Domain:** Windows desktop shell — Wails v2 + WebView2 + fyne.io/systray; RAM measurement under RDS
**Confidence:** HIGH (stack, tray pattern, window lifecycle, mutex); MEDIUM (RAM outcome — must be measured); MEDIUM (WM_QUERYENDSESSION hidden HWND wiring — documented but not project-tested)

## Summary

Phase 7 builds the minimal Wails v2.12.0 desktop shell for go-mapi: tray icon, hide-to-tray window, single-instance mutex, logoff handling, and the folded-in `%TEMP%\go-mapi\` watcher. The phase is a **hard gate** — RAM on an RDS-simulated Hetzner Windows Server 2022 VM must fall ≤ 80 MB private working set per session at 5-min idle (post-WebView2 init) before any Phase 8 work begins.

Stack is fully locked upstream (in `.planning/research/STACK.md` and `.planning/STATE.md`): Wails v2.12.0 stable (not v3 alpha), fyne.io/systray v1.12.0 via `RunWithExternalLoop`, Go 1.23, Svelte 5 + TypeScript for frontend, fsnotify v1.7.0 preserved from v2.x. The ARCHITECTURE.md dissent recommending Wails v3 is explicitly overridden by the 3:1 researcher consensus and by CONTEXT.md §canonical_refs.

**Primary recommendation:** Execute the locked stack. Scaffold `src/app/` as a new workspace alongside (not replacing) `src/native-host/`, extract shared Go code into `internal/mapi/`, wire the tray via `RunWithExternalLoop`, and deliver the RAM measurement as a documented artifact in VERIFICATION.md before Phase 8 is unblocked.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**RAM Measurement Methodology**
- **D-01:** Pass/fail metric is **Private Working Set** (Task Manager "Memory (private working set)"). Rationale: excludes shared WebView2/Edge runtime pages — fair for RDS where many instances share the runtime. Total Working Set would overcount; Commit Size includes paged-out memory and does not reflect real pressure.
- **D-02:** RDS simulation: spin up a **Hetzner Windows Server 2022 VM** with 5–10 concurrent user sessions (real HDESKTOP isolation). Cheaper alternatives (N instances under one workstation user) under-report RDS cost and are rejected.
- **D-03:** Measurement protocol: three samples per session — **cold start**, **5-min idle**, and **after first window toggle** (post-WebView2 init). Run 3 iterations per scenario, average. This captures startup cost, steady state, and post-init steady state — all three matter for the lazy-init decision.
- **D-04:** Gate threshold is **≤ 80 MB private working set per session, measured at 5-min idle (post-WebView2-init)**. 30 MB remains a documented stretch goal; not a pass criterion.

**Main Window Content (Phase 7 scope)**
- **D-05:** Main window renders a **minimal live queue list** (sender, subject, timestamp; no attachment count) fed by Wails events from the folded-in watcher. **No per-email action buttons** — Create-draft/Dismiss are Phase 9. Giving Svelte something real to render exercises the RAM path (empty windows under-measure).
- **D-06:** Window toggle behavior: left-click tray icon = show + focus; left-click when visible = hide. Standard Windows tray pattern (OneDrive/Teams). Hide never quits; only the Quit menu item or Windows logoff quits.

**Codebase Structure Migration**
- **D-07:** Introduce a **new `src/app/` workspace alongside the existing `src/native-host/`** in Phase 7. Do not move or rename `src/native-host/` yet. Keeps native-host buildable for rollback and keeps the RAM-gate phase focused; the full absorb happens after Phase 7 passes.
- **D-08:** Shared Go code (watcher, validator, gmail client, protocol types) is **extracted to an `internal/` Go package** (suggested name `internal/mapi` — planner decides final structure) imported by both `src/native-host/` and `src/app/`. Single source of truth; no duplication. Extraction happens in Phase 7 as prerequisite to SHELL-06.
- **D-09:** `src/app/` is a new changesets workspace. Svelte frontend lives under `src/app/frontend/` per research ARCHITECTURE.md. Planner to verify `go.work` layout + changesets config.

**Tray Menu + Icon Assets**
- **D-10:** Phase 7 tray right-click menu: **Show + Quit only**. Explicit deviation from SHELL-02 wording ("Show / Pause watching / Quit") — Pause-watching is deferred to Phase 9 when queue actions exist. Phase 9 CONTEXT must pick this up and complete SHELL-02.
- **D-11:** Ship **two icon variants** in Phase 7: **idle + error**. Error covers watcher init failure and WebView2 missing / bootstrap failure. Has-queue variant is deferred to Phase 9 (nothing to reflect yet). Light/dark variants are Claude's discretion if time permits.

**RAM Gate Failure Contingency**
- **D-12:** If measurement exceeds the gate, **halt Phase 7 and open a `/gsd-explore` re-evaluation session**. Document the measured value, scenario, and per-sample variance in VERIFICATION.md. No reflexive framework swap — the explore session decides: drop RDS target, swap framework (Tauri/Fyne-native/direct-Win32), scope-reduce, or accept overage with stakeholder sign-off. Phase 8 does **not** begin until a decision is recorded.

### Claude's Discretion

- Sample size `N` for concurrent RDS sessions (5 vs 10) — planner chooses based on Hetzner VM sizing; min 5.
- RAM-result interpretation — mean of 3 runs is pass/fail; max of 3 runs reported for transparency.
- Measurement automation format (Pester 5 script vs manual Get-Process + documented procedure) — prefer Pester to match v2.0 testing pattern, but manual is acceptable for a one-shot gate.
- Tray-icon light/dark variants (ship one or both).
- Empty-queue state copy in the main window.
- Default window size/position; geometry persistence across restarts (likely deferred to a later phase).
- Logging location + format for the new Wails app (align with existing `native-host.log` convention).
- Exact name of the extracted internal package (`internal/mapi`, `internal/core`, etc.).

### Deferred Ideas (OUT OF SCOPE)

- **Pause-watching tray menu item** — Phase 9 (needs queue UI + state plumbing).
- **Has-queue tray icon variant** — Phase 9 (nothing to reflect in Phase 7).
- **Per-email actions (Create draft / Dismiss)** — Phase 9.
- **OAuth / Gmail draft logic / 30s timeout + retry on `gmail.go`** — Phase 8.
- **WinRT toast notifications / AppUserModelID** — Phase 9 (toast work), registered permanently in Phase 10 installer.
- **NSIS installer / WebView2 bootstrapper / Firewall rule / v2.x cleanup** — Phase 10.
- **Autoupdate (go-selfupdate) + extension-store retirement** — Phase 11.
- **Full `src/native-host/` absorb into `src/app/`** — after Phase 7 passes; not during the gate.
- **Window geometry persistence across restarts** — later phase (UX polish).
- **Light/dark tray icon auto-switching** — Claude's discretion in Phase 7 if trivial; otherwise later.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SHELL-01 | Wails v2.12.0 app builds and runs on Windows 10/11 with WebView2 runtime present | §Standard Stack (Wails v2.12.0 + Go 1.23 + svelte-ts template); §Architecture Patterns §1 (scaffold) |
| SHELL-02 | System tray icon; left-click toggles window; right-click menu (Show / Quit — Pause-watching deferred per D-10) | §Standard Stack (fyne.io/systray v1.12.0); §Architecture Patterns §2 (RunWithExternalLoop); §Pitfall 7 (tray race) |
| SHELL-03 | Main window shows email queue; close hides to tray | §Architecture Patterns §3 (WindowClosing interceptor, Hidden:true); §Code Examples (WindowHide) |
| SHELL-04 | Named mutex prevents multiple instances; second launch raises existing window | §Architecture Patterns §4 (named mutex via `golang.org/x/sys/windows`); §Pitfall 7 |
| SHELL-05 | App exits cleanly on Windows logoff/shutdown (WM_QUERYENDSESSION) | §Architecture Patterns §5 (hidden message-only HWND); §Pitfall 7 |
| SHELL-06 | Watcher folds into Wails app; runs whether window visible or hidden | §Architecture Patterns §6 (WatcherCallback + EventsEmit); §Don't Hand-Roll (reuse fsnotify watcher from native-host) |
| SHELL-07 | Tray icon reflects queue state (idle/error only in Phase 7 per D-11) | §Standard Stack (systray.SetIcon); §Code Examples (icon swap) |
| QUAL-01 | RAM ≤ 80 MB private working set idle, RDS-simulated, 5-min post-WebView2-init | §Runtime State Inventory; §Environment Availability; §Pitfall 1 (WebView2 80–150 MB baseline) |
| QUAL-02 | App runs without Chrome/Edge installed (WebView2 runtime only) | §Standard Stack (Evergreen Runtime); §Pitfall 2 |
| QUAL-04 | `go test -race ./...` green on new Go code | §Architecture Patterns §7 (concurrency pattern preserved from native-host); §Common Pitfalls |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- **Platform:** Windows 10/11 only (MAPI is Windows API)
- **License:** LGPL-3.0 — constrains dependency choices; all locked libraries are LGPL/MIT compatible
- **Privacy:** No telemetry, no long-term content retention, no network calls outside Gmail API (Phase 8) + GitHub Releases (Phase 11) — Phase 7 has no network calls at all
- **Toolchain (dev):** Windows + Node 18+ + Go 1.23 (bump from 1.21) + MinGW + CMake 3.16+
- **Type safety:** Strict TS, no `any` (Svelte frontend); idiomatic Go (error wrapping with `%w`, lowercase error strings, `sync.RWMutex` + `chan struct{}` done-signals)
- **Logging convention:** Timestamped RFC3339 + `[INFO]`/`[ERROR]` prefix, file-based (align with `native-host.log` pattern)
- **Changesets monorepo:** New `src/app/` workspace must be added per v2.1.0 Phase 6 convention (own `package.json`, own version track)
- **Lockfile discipline** (global rule): commit `package.json` + `package-lock.json` together when adding the new workspace; CI uses `npm ci`
- **Git:** Work on `develop`; no direct commits to `main`
- **Verify before assuming:** Check `go.mod`, existing `watcher.go`, existing `protocol.go` before extracting — do not assume shape
- **Scope discipline:** RAM gate is the phase's point. No drive-by feature work; OAuth/draft/toasts/installer are all deferred to downstream phases

## Standard Stack

All versions and choices below are locked by upstream research (`.planning/research/STACK.md`, 2026-04-12) and CONTEXT.md §canonical_refs. Phase 7 consumes; it does not re-debate.

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| github.com/wailsapp/wails/v2 | **v2.12.0** | Desktop app shell, WebView2 bridge, window/build toolchain | Only stable Wails release; v3 is alpha with known tray race. `[CITED: pkg.go.dev/github.com/wailsapp/wails/v2 — confirmed 2026-04-12 in STACK.md]` |
| fyne.io/systray | **v1.12.0** | System tray icon + context menu | `RunWithExternalLoop` returns start/end hooks for host-message-loop apps. `getlantern/systray` deadlocks against Wails WndProc. `[CITED: pkg.go.dev/fyne.io/systray; github.com/wailsapp/wails/discussions/4514]` |
| github.com/fsnotify/fsnotify | **v1.7.0** | Filesystem watching on `%TEMP%\go-mapi\` | Already used by v2.x native-host; migrate unchanged `[VERIFIED: src/native-host/go.mod]` |
| golang.org/x/sys/windows | v0.4.0+ | Named mutex (`CreateMutex`), `WM_QUERYENDSESSION` window reg, optional `FindWindow`/`SetForegroundWindow` for single-instance raise | Standard Go Windows syscall package; already a transitive dep `[VERIFIED: src/native-host/go.mod]` |
| Svelte | **5.x latest stable** | Frontend UI (queue list) | Zero-runtime compile; matters at 30 concurrent RDS renderers vs React 42 KB. `[CITED: STACK.md §4]` |
| TypeScript | 5.x (Wails svelte-ts template default) | Type safety in frontend | Matches project convention (strict mode, no `any`) |
| Vite | (embedded in Wails svelte-ts template) | Bundler | Provided by `wails init -t svelte-ts` |
| Go | **1.23** (bump from 1.21) | Backend | Wails v2 tested baseline; Go 1.22 loop-variable fix avoids goroutine bugs. `[CITED: STACK.md §8]` |
| Node | 18+ (existing) | Wails frontend build + changesets | Already required by monorepo `[VERIFIED: package.json]` |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| WebView2 Evergreen Runtime | Latest (OS-managed) | Webview renderer | **Runtime requirement**, not a dev dep. Phase 7 assumes it's installed on the dev machine and the RDS VM. Bootstrapping is Phase 10 (installer). `[CITED: Microsoft WebView2 distribution docs]` |

**Not added in Phase 7** (deferred):
- `golang.org/x/oauth2`, `github.com/zalando/go-keyring` — Phase 8
- `github.com/creativeprojects/go-selfupdate` — Phase 11
- WinRT toast library (tbd) — Phase 9

### Alternatives Considered (all rejected upstream)

| Instead of | Could Use | Tradeoff | Rejected Because |
|------------|-----------|----------|------------------|
| Wails v2.12.0 | Wails v3 alpha | Built-in tray; cleaner API | Alpha-channel risk; explicit "may contain bugs"; ARCHITECTURE.md dissent overridden by SUMMARY §consensus |
| fyne.io/systray | getlantern/systray | Larger community | Deadlocks against Wails Windows message loop |
| fyne.io/systray | ra1phdd/systray-on-wails | Purpose-built wrapper | 0-version pre-release, one maintainer, stale |
| Wails | Tauri / Fyne / Electron | — | Tauri adds Rust (third compiled lang); Fyne forces Go widgets; Electron 150 MB Chromium blows RAM budget |
| Svelte 5 | React 18 | Familiar (current popup code) | ~42 KB runtime resident per renderer × N sessions |

### Installation

```bash
# Dev machine (one-time)
go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0

# Inside src/app/ (new workspace)
wails init -n go-mapi-app -t svelte-ts        # if scaffolding from scratch
# or: hand-craft layout per Architecture Patterns §1 to fit the shared internal/ layout

cd src/app
go mod edit -go=1.23
go get github.com/wailsapp/wails/v2@v2.12.0
go get fyne.io/systray@v1.12.0
go get github.com/fsnotify/fsnotify@v1.7.0
go get golang.org/x/sys@latest

# Frontend
npm install   # runs from src/app/frontend (or root if workspace-wired)
```

### Version Verification

Versions below are carried from upstream research dated 2026-04-12 (one day old). Before Wave 0 writes the first `go.mod`, planner SHOULD re-verify with:

```bash
go list -m -versions github.com/wailsapp/wails/v2
go list -m -versions fyne.io/systray
```

If a newer patch version of Wails v2 has shipped (e.g., v2.12.1), adopt it; do **not** move to v3 without a new discuss session. `[ASSUMED]` tag applies if versions are not re-verified at planning time.

## Architecture Patterns

### Recommended Project Structure

```
go-mapi/
├── src/
│   ├── interceptor/              # UNCHANGED — C++ MAPI DLL
│   ├── native-host/              # KEPT unchanged in Phase 7 (D-07); imports from internal/
│   ├── app/                      # NEW — Wails desktop app workspace
│   │   ├── main.go               # wails.Run, App options (Hidden:true, WindowClosing hook)
│   │   ├── app.go                # App struct, bound methods (minimal: GetQueue only in Phase 7)
│   │   ├── tray.go               # fyne.io/systray RunWithExternalLoop wiring, menu, icon state
│   │   ├── singleinstance.go     # Named mutex + existing-window raise
│   │   ├── sessionend.go         # Hidden message-only HWND for WM_QUERYENDSESSION
│   │   ├── icons/                # idle.ico, error.ico (D-11)
│   │   ├── frontend/             # Svelte 5 + TypeScript (wails init -t svelte-ts)
│   │   │   ├── src/App.svelte
│   │   │   ├── src/lib/queue.ts  # EventsOn("queue-update") subscriber
│   │   │   ├── package.json
│   │   │   └── vite.config.ts
│   │   ├── wails.json
│   │   ├── go.mod                # module: github.com/marcfargas/go-mapi/app
│   │   └── package.json          # changesets workspace marker
│   └── installer/                # Phase 10 work; untouched
├── internal/
│   └── mapi/                     # D-08 — shared Go package
│       ├── watcher.go            # EXTRACTED from src/native-host/watcher.go (no behavior changes)
│       ├── protocol.go           # EXTRACTED (MailMessage, validateMailMessage, normalize*)
│       ├── gmail.go              # EXTRACTED (unused in Phase 7; avoids second migration later)
│       └── *_test.go             # tests follow source
├── go.work                        # NEW — workspace file listing src/native-host, src/app, tests/...
├── package.json                   # root workspace; add src/app (+ src/app/frontend if needed)
└── tests/protocol-fixtures/       # UNCHANGED; internal/mapi/ tests read from this path
```

**Planner note on final package naming:** `internal/mapi` is a suggestion (per D-08). Alternatives: `internal/core`, `internal/queue`. Pick once; do not churn.

**go.work layout:**

```
go 1.23
use (
    ./src/native-host
    ./src/app
)
```

This enables both modules to consume `internal/mapi` during development without replace-directives. Placing `internal/` at repo root (not inside a module) is intentional: Go treats `internal/` as a compile-time boundary only when it's inside a module, but with `go.work` both sibling modules can import from a third module housed at `./internal/mapi/` (with its own `go.mod`) or as a shared module at the repo root. **Planner MUST verify the exact go.work + go.mod layout** — two viable shapes:

1. **`internal/mapi/` as its own module** at `./internal/mapi/go.mod` (module path `github.com/marcfargas/go-mapi/internal/mapi`), both apps import it. Works with `go.work` listing all three.
2. **Repo-root go.mod** housing `internal/mapi`, with `src/app/` and `src/native-host/` as sub-modules using `replace` or workspace directives.

Option 1 is cleaner. `[CITED: go.dev workspace docs]`

### Pattern 1: Wails App Bootstrap (Hidden-on-start Tray App)

**What:** Wails `Run` configured so the window never flashes on startup; tray owns UI until user opens window.

**When to use:** Every tray-first app in Wails v2 (the standard recipe).

**Example (assembled from STACK.md §5 + ARCHITECTURE.md event patterns + PITFALLS.md #7 mitigations):**

```go
// src/app/main.go — Source: STACK.md §1, ARCHITECTURE.md §Window Lifecycle, PITFALLS.md §7
package main

import (
    "embed"
    "context"

    "github.com/wailsapp/wails/v2"
    "github.com/wailsapp/wails/v2/pkg/options"
    "github.com/wailsapp/wails/v2/pkg/options/windows"
    wruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed all:frontend/dist
var assets embed.FS

var Version = "0.0.0-dev" // injected via -ldflags

func main() {
    // Single-instance check BEFORE Wails init (see Pattern 4)
    if existing := acquireSingleInstance(); existing != nil {
        raiseExisting(existing)
        return
    }
    defer releaseSingleInstance()

    app := NewApp()

    err := wails.Run(&options.App{
        Title:             "go-mapi",
        Width:             800,
        Height:            600,
        Assets:            assets,
        OnStartup:         app.startup,
        OnShutdown:        app.shutdown,
        OnBeforeClose:     app.beforeClose,   // intercept window close → hide
        Bind:              []interface{}{app},
        HideWindowOnClose: true,               // belt-and-braces
        StartHidden:       true,               // window is never shown until user asks
        Windows: &windows.Options{
            WebviewIsTransparent: false,
            WindowIsTranslucent:  false,
            DisableWindowIcon:    false,
        },
    })
    if err != nil {
        // Log to %APPDATA%\go-mapi\app.log or %TEMP%\go-mapi\app.log (Claude's discretion)
    }
}
```

```go
// src/app/app.go
type App struct {
    ctx     context.Context
    watcher *mapi.EmailWatcher   // from internal/mapi
    trayEnd func()               // systray cleanup hook
}

func (a *App) startup(ctx context.Context) {
    a.ctx = ctx

    // Start tray (Pattern 2)
    start, end := systray.RunWithExternalLoop(a.onTrayReady, a.onTrayExit)
    start()
    a.trayEnd = end

    // Register WM_QUERYENDSESSION hidden window (Pattern 5)
    go registerSessionEndHandler(a.onSessionEnd)

    // Fold in watcher (Pattern 6)
    a.watcher = mapi.NewEmailWatcher(watchDir, a.onQueueChange)
    go a.watcher.Start()
}

func (a *App) shutdown(ctx context.Context) {
    if a.watcher != nil {
        a.watcher.Stop()
    }
    if a.trayEnd != nil {
        a.trayEnd()
    }
}

func (a *App) beforeClose(ctx context.Context) (prevent bool) {
    wruntime.WindowHide(ctx)
    return true // prevent actual close — only tray Quit or WM_QUERYENDSESSION quits
}

// GetQueue is the ONLY bound method in Phase 7 (D-05).
func (a *App) GetQueue() []mapi.EmailWithId {
    return a.watcher.Snapshot()
}

func (a *App) onQueueChange() {
    wruntime.EventsEmit(a.ctx, "queue-update")
}
```

### Pattern 2: fyne.io/systray via RunWithExternalLoop

**What:** Attach tray to a host message loop owner (Wails).

**When to use:** Wails v2 + any systray. Non-negotiable: `Run()` blocks and deadlocks; `RunWithExternalLoop` returns.

**Example:**

```go
// src/app/tray.go — Source: STACK.md §5, fyne.io/systray docs
//go:embed icons/idle.ico
var idleIcon []byte
//go:embed icons/error.ico
var errorIcon []byte

func (a *App) onTrayReady() {
    systray.SetIcon(idleIcon)
    systray.SetTooltip("go-mapi — idle")

    mShow := systray.AddMenuItem("Show", "Open main window")
    systray.AddSeparator()
    mQuit := systray.AddMenuItem("Quit", "Exit go-mapi")

    go func() {
        for {
            select {
            case <-mShow.ClickedCh:
                wruntime.WindowShow(a.ctx)
                wruntime.WindowUnminimise(a.ctx)
                wruntime.WindowSetAlwaysOnTop(a.ctx, true)
                wruntime.WindowSetAlwaysOnTop(a.ctx, false)
            case <-mQuit.ClickedCh:
                wruntime.Quit(a.ctx)
                return
            }
        }
    }()
}

func (a *App) onTrayExit() { /* no-op; systray.Quit() triggers */ }

// Left-click toggle is via systray's OnClick (v1.12.0+); wire to:
//   if window visible → WindowHide; else → WindowShow
```

Left-click toggle (D-06): `fyne.io/systray` v1.12.0 exposes `OnClick` / left-click callback support on Windows. Verify at Wave 0 spike; fallback is double-click on Windows or custom hotkey. `[ASSUMED]` — confirm in spike.

### Pattern 3: Window Lifecycle (Never-Flash)

Start hidden, always hide on close, only quit on explicit tray action or session end. Combined with single-instance mutex, this avoids the Pitfall 7 tray-race blank-flash.

Options recipe: `StartHidden: true` + `HideWindowOnClose: true` + `OnBeforeClose` returning `true` after `WindowHide`. Redundant but defensive against version drift.

### Pattern 4: Single-Instance Named Mutex

**What:** Windows-kernel named mutex prevents second process from running; second launch raises existing window.

**Example:**

```go
// src/app/singleinstance.go — Source: ARCHITECTURE.md §Single-instance, PITFALLS.md §7
import "golang.org/x/sys/windows"

const mutexName = `Global\go-mapi-singleton-v3`   // Global\ scope for RDS per-session needs discussion
var mutexHandle windows.Handle

func acquireSingleInstance() (existing windows.Handle) {
    name, _ := windows.UTF16PtrFromString(mutexName)
    h, err := windows.CreateMutex(nil, false, name)
    if err != nil {
        return 0 // proceed; better to run than fail-closed
    }
    if windows.GetLastError() == windows.ERROR_ALREADY_EXISTS {
        // Another instance owns the mutex. Find its window and raise it.
        return findExistingWindow()
    }
    mutexHandle = h
    return 0
}

func releaseSingleInstance() {
    if mutexHandle != 0 {
        windows.CloseHandle(mutexHandle)
    }
}
```

**RDS consideration:** `Global\` mutex name is machine-wide. On RDS, each user session must have its own running instance — use session-scoped name `Local\go-mapi-singleton-v3` instead (the default `Local\` prefix scopes to the Windows session). `[CITED: Microsoft docs on kernel object namespaces]` **Planner decision:** use `Local\` prefix (or no prefix, which defaults to `Local\`) so each RDS user gets their own instance.

**Raising existing window:** use `FindWindowW` with the Wails window title or a custom window class, then `ShowWindow(SW_RESTORE) + SetForegroundWindow`. Alternatively, send a custom `WM_USER` message via a named pipe or a shared event — more robust but more code. Start with `FindWindow`.

### Pattern 5: WM_QUERYENDSESSION via Hidden Message-Only Window

**What:** Wails v2 does not expose logoff hooks; register a separate message-only HWND (`HWND_MESSAGE` parent) to receive `WM_QUERYENDSESSION` / `WM_ENDSESSION`.

**When to use:** Any Windows app that needs to flush state on logoff/shutdown. Required by SHELL-05.

**Example skeleton (adapted from ARCHITECTURE.md + PITFALLS.md §7):**

```go
// src/app/sessionend.go — Source: PITFALLS.md §7, Windows SDK docs
// Pseudocode — actual wiring uses golang.org/x/sys/windows + syscall for WndProc
// Register a window class with a custom WndProc
// Create window with HWND_MESSAGE as parent
// WndProc:
//   case WM_QUERYENDSESSION: signal shutdown channel; return TRUE
//   case WM_ENDSESSION: call cleanup; return 0
// Pump messages in a dedicated goroutine via GetMessage/DispatchMessage
```

**Wave 0 spike needed:** This is the single LOW-confidence area in Phase 7. A working minimal example must exist before the full app lifecycle is wired. Reference: [Raymond Chen — How do I create a message-only window?](https://devblogs.microsoft.com/oldnewthing/20171218-00/?p=97595) `[CITED]`.

### Pattern 6: Watcher → Wails Event Bus

**What:** `internal/mapi.EmailWatcher` gets a callback parameter (already structurally compatible with existing `NativeMessaging` hook — just swap the output). App struct translates callback invocations to `EventsEmit(ctx, "queue-update")`.

**When to use:** The phase's whole "fold watcher in" story.

**Migration shape:**
- Current `src/native-host/watcher.go`: watcher calls `nm.SendEmail(msg)` on new/changed/removed.
- New `internal/mapi/watcher.go`: watcher accepts `type WatcherCallback interface { OnQueueChanged(snapshot []EmailWithId) }` or a plain `func()` — planner chooses. Native-host adapter implements the interface and keeps emitting to stdin/stdout; Wails App implements it and calls `EventsEmit`.
- Frontend (Svelte) subscribes: `EventsOn("queue-update", refetchQueue)`.

### Pattern 7: Concurrency (Preserved from native-host)

- `sync.RWMutex` on shared queue state
- `chan struct{}` done-signal for goroutine shutdown (clean for QUAL-04 `-race` green)
- `defer` for unlock/close
- fsnotify debounce (500 ms), AV-lock retry (3× 200 ms) — carry forward verbatim from existing watcher

### Anti-Patterns to Avoid

- **Using Wails v3 alpha** — explicit override. Don't debate, don't dabble.
- **Using `getlantern/systray`** — deadlocks. Use `fyne.io/systray` v1.12.0 with `RunWithExternalLoop`.
- **Calling `systray.Run()`** — blocks; deadlocks with Wails. Always `RunWithExternalLoop`.
- **Relying on `WindowStartState: WindowStartStateMinimised`** — can cause blank-flash (PITFALLS.md §7). Use `StartHidden: true` + `HideWindowOnClose: true`.
- **Storing the frontend as React** — upstream-rejected. Use Svelte 5 + TypeScript.
- **Moving or renaming `src/native-host/` in Phase 7** — D-07 explicitly forbids. Keep both running.
- **Hand-rolling fsnotify-equivalent** — reuse extraction. Don't regress the v2.x debounce + AV retry tuning.
- **Forcing WebView2 load at startup** — contradicts QUAL-01 lazy-init intent. Let `StartHidden: true` keep WebView2 uninitialized until first window open; measure RAM in that state.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Filesystem watcher | Custom inotify-style polling | `github.com/fsnotify/fsnotify@v1.7.0` (already in use) | Edge cases around AV locking, moves, debounce |
| Single-instance enforcement | File lock / port bind / PID file | Named kernel mutex via `golang.org/x/sys/windows.CreateMutex` | Atomic, race-free, process-death-safe |
| System tray | Direct Shell_NotifyIcon Win32 calls | `fyne.io/systray@v1.12.0` | Menu, icon, tooltip, event wiring done right |
| Window message loop | Custom WndProc hosting the webview | Wails owns it; hook via `OnStartup`/`OnBeforeClose`/`EventsEmit` | Wails has already solved the WebView2 embedding |
| Svelte/JS bridge | `postMessage` scaffolding | Wails binding generator (`wails generate module`) — emits TS types from bound Go methods | Type-safe, auto-regenerates |
| Content-hash IDs for queued emails | New hash scheme | Reuse existing SHA256(body+filename) from `src/native-host/watcher.go` | Deterministic; already test-covered |
| Logging | Structured-log library | Existing `logInfo`/`logError` pattern from native-host, extracted into `internal/mapi/logging.go` | Project convention; keep one style |

**Key insight:** Phase 7 is a scaffold + gate, not a greenfield. Every piece of pure Go logic already exists in `src/native-host/`; the phase's real work is (a) extracting that cleanly into `internal/mapi/`, (b) wiring Wails + systray around it, (c) adding Windows-specific shell concerns (mutex, session-end), and (d) measuring RAM.

## Runtime State Inventory

> Phase 7 is a **partial refactor** (code extraction to `internal/mapi/`) bundled with **greenfield scaffold** (`src/app/`). The refactor slice merits a state inventory.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None — v2.x stores queued JSON in `%TEMP%\go-mapi\`, no renames involved. Phase 7 path is unchanged. `[VERIFIED: src/native-host/watcher.go — uses existing %TEMP% path; no renames in D-07..D-09]` | None |
| Live service config | None — v3.0 Phase 7 has no external services. Chrome Native Messaging manifests (`%APPDATA%\Google\Chrome\NativeMessagingHosts\com.gomapi.host.json`, and Edge equivalent) still exist from v2.x but are untouched in Phase 7 — cleanup is Phase 10 (INST-03). `[VERIFIED: D-07 keeps native-host buildable; PITFALLS.md §9]` | None in Phase 7. Phase 10 removes them. |
| OS-registered state | None new. v2.x has `HKLM\SOFTWARE\Clients\Mail\go-mapi` (MAPI handler) — untouched (Phase 7 does not change interceptor). No new Scheduled Tasks, services, AppUserModelID, or shortcuts in Phase 7 (all deferred). `[VERIFIED: D-deferred list, installer in Phase 10]` | None |
| Secrets/env vars | None — OAuth is Phase 8. No secret-manager keys touched. Existing GCP OAuth client ID baked into v2.x extension manifest is irrelevant to Phase 7 (extension not touched). | None |
| Build artifacts / installed packages | **`src/native-host/build/go-mapi-host.exe`** remains valid (native-host stays buildable per D-07). **New:** `src/app/build/bin/go-mapi.exe` (Wails output) — new artifact, no stale predecessor. `package-lock.json` at repo root will change when `src/app/` workspace is added — must be committed. `[VERIFIED: scripts in package.json; lockfile-discipline.md]` | Commit `package.json` + `package-lock.json` together when adding `src/app` workspace. Verify native-host still builds after `internal/mapi/` extraction. |

**Nothing found in categories 1, 2, 3, 4** — stated explicitly to distinguish from "not checked."

**The canonical question:** *After every file in the repo is updated, what runtime systems still have the old string cached, stored, or registered?* Answer for Phase 7: **nothing**. No renames, no migrations, no user-visible name changes. The extraction is code-level only.

## Common Pitfalls

### Pitfall 1: RAM Budget Blown (Project-Blocking)

**What goes wrong:** WebView2 is 80–150 MB per process group, not the 10–30 MB that the original PROJECT.md target implied. On RDS with 30 HDESKTOP-isolated sessions, sharing across sessions is impossible — each session spins its own WebView2 group. Total RAM footprint can hit 2.4–4.5 GB.

**Why it happens:** "WebView2 shares the Edge runtime" holds at the DLL level but not at the process-group level. HDESKTOP isolation is a hard Windows boundary.

**How to avoid:**
- Lazy-init: `StartHidden: true` means WebView2 is not instantiated until the user first opens the window. Measure cold start and 5-min idle before any window open — the phase's gate is explicitly post-WebView2-init steady state (D-03).
- `CoreWebView2MemoryUsageTargetLevel.Low` on window hide (via Wails' WebView2 environment options) — returns memory when tray-only. Verify API exposure in Wails v2.12.0 during the spike. `[ASSUMED that Wails v2 exposes this — verify]`
- Keep the Svelte bundle minimal. No Bootstrap CSS, no analytics, no heavy components. Queue list is text.

**Warning signs:**
- Task Manager shows > 80 MB Private Working Set per session after 5 min idle
- `msedgewebview2.exe` appears multiple times per session (expected — not a bug; the count measures the cost)
- Per-sample variance > 20 % across the three runs (suggests a background job is leaking)

**If it fails:** D-12 — halt Phase 7, open `/gsd-explore`, document measurement + variance in VERIFICATION.md, pick a new direction before Phase 8.

### Pitfall 2: Tray Race — Blank Flash or Dual Instances

**What goes wrong:** Without the full recipe, users see a blank window flash on login or two tray icons after a crash-restart.

**How to avoid:** Apply **all** of these:
1. `StartHidden: true` in Wails options
2. `HideWindowOnClose: true` defensive default
3. `OnBeforeClose` interceptor that calls `WindowHide` and returns `true`
4. Named mutex (`Local\go-mapi-singleton-v3`) at `main()` entry **before** `wails.Run`
5. Existing-window raise on second-instance detection

**Warning signs:** blank flash; two tray icons; duplicate drafts on single MAPI send.

### Pitfall 3: WM_QUERYENDSESSION Not Handled

**What goes wrong:** Windows kills the process on logoff; in-flight state lost; in Phase 7 specifically, the watcher goroutine dies mid-debounce and a queued JSON may remain in a half-written state.

**How to avoid:** Pattern 5 — hidden message-only HWND with explicit `WM_QUERYENDSESSION` handler that signals watcher shutdown and drains the done-channel before returning. Wave 0 must include a working spike.

### Pitfall 4: Go Version Sensitivity

**What goes wrong:** Wails v2 "fails silently on some 1.24 builds" per SUMMARY.md.

**How to avoid:** Pin Go exactly at 1.23 in the new `src/app/go.mod` and in CI. Document the pin in the workspace README.

### Pitfall 5: Race Detector Failures (QUAL-04)

**What goes wrong:** New goroutines (tray event loop, session-end handler, watcher callback dispatched to Wails context) introduce races against the existing `sync.RWMutex`-protected queue map.

**How to avoid:**
- Keep `EventsEmit` calls off hot watcher paths where they'd cross mutex boundaries; dispatch via buffered channel drained by a single goroutine.
- `go test -race ./...` in CI gate on both `src/native-host/` (legacy) and `src/app/` + `internal/mapi/` (new).
- No shared state between tray `ClickedCh` goroutine and watcher internals — go through App struct methods only.

### Pitfall 6: Test Path Drift Post-Extraction

**What goes wrong:** Moving `watcher_test.go` → `internal/mapi/watcher_test.go` breaks fixture paths (`../../tests/protocol-fixtures/`).

**How to avoid:**
- Use `testdata/` conventions or a central `testutil.FixturePath()` helper that resolves repo-root-relative.
- Run the full existing test suite post-extraction before adding any new code. Extraction must be behavior-preserving.

### Pitfall 7: Changesets Monorepo Regression

**What goes wrong:** New `src/app/` workspace not wired into changesets; v3.0 version bumps skip it.

**How to avoid:** Verify `.changeset/config.json` includes `src/app` and (if applicable) `src/app/frontend`. Add a Phase 6-pattern `package.json` with name + version. Commit `package-lock.json` in the same commit.

## Code Examples

All examples live under §Architecture Patterns (inline with the pattern they demonstrate) to avoid duplication. Key anchors:

- Wails options + lifecycle hooks → Pattern 1
- Tray wiring with `RunWithExternalLoop` → Pattern 2
- Named mutex + existing-window raise → Pattern 4
- WM_QUERYENDSESSION hidden HWND (skeleton) → Pattern 5
- Watcher → `EventsEmit` translation → Pattern 6

Sources (already cited inline):
- STACK.md §1 (Wails v2 recipe)
- STACK.md §5 (fyne.io/systray RunWithExternalLoop)
- ARCHITECTURE.md §Window Lifecycle, §Single-instance, §Event channels
- PITFALLS.md §1 (RAM), §7 (tray race), §11 (Go pin)

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Chrome Extension + Native Host (v2.x) | Wails desktop app + preserved MAPI DLL | v3.0 Wails Pivot (2026-04-12) | Single installer; no browser dep; new RAM profile to validate |
| Go 1.21 (native-host) | Go 1.23 (src/app) | Phase 7 | Loop-variable capture fix; Wails-tested baseline |
| React 18 + React-Bootstrap (extension popup) | Svelte 5 + plain CSS | Phase 7 frontend scaffold | ~40 KB renderer memory savings × N sessions |
| Chrome Native Messaging stdio protocol | Wails JS↔Go bindings + event bus | Phase 7 | Type-safe; no 4-byte-framing overhead; no stdin/stdout race |
| `chrome.identity.getAuthToken()` (v2.x) | PKCE loopback OAuth (Phase 8 work, not Phase 7) | Phase 8 | Phase 7 has no OAuth — noting for context only |

**Deprecated / outdated:**
- Wails v3 alpha as Phase 7 framework — explicit SUMMARY override, do not reopen
- `getlantern/systray` — incompatible with Wails v2 message loop
- `minio/selfupdate` — inactive since 2022 (Phase 11 concern, not here)

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Wails v2.12.0, fyne.io/systray v1.12.0, Go 1.23, golang.org/x/sys current — versions unchanged since 2026-04-12 | Standard Stack | Low — one-day-old research. Planner should still re-run `go list -m -versions` at Wave 0 to catch a patch release. |
| A2 | `fyne.io/systray` v1.12.0 exposes a left-click/`OnClick` callback on Windows (for D-06 toggle UX) | Pattern 2 | Medium — if absent, fall back to double-click or open-on-menu. Planner should include a Wave 0 spike to confirm. |
| A3 | Wails v2.12.0 exposes a way to pass `CoreWebView2MemoryUsageTargetLevel` (via `windows.Options` or env hook) to drop memory on window hide | Common Pitfalls §1 | Medium — if not exposed, alternative is not fighting the engine and relying on lazy-init + StartHidden alone. May still pass the 80 MB gate; worth confirming. |
| A4 | `internal/mapi/` as a separate module (option 1 in Architecture Patterns) is the cleanest go.work shape for this repo | Architecture Patterns §Project Structure | Low — either shape works; planner picks based on what looks saner after touching the code. |
| A5 | `Local\go-mapi-singleton-v3` as the mutex name correctly scopes per-RDS-session on Windows Server 2022 | Pattern 4 | Low — `Local\` prefix is documented Windows behavior. Verify during RAM measurement (launching in two sessions should yield two live instances). |
| A6 | Extracting `watcher.go`, `protocol.go`, `gmail.go` into `internal/mapi/` is behavior-preserving and preserves existing unit tests without edits beyond import paths and fixture-path resolution | Pitfalls §6 | Medium — tests may reference private types or package-local state. Planner: run existing suite post-extraction as the very first verification step. |
| A7 | WebView2 Evergreen Runtime is already installed on a fresh Windows Server 2022 VM via Windows Update rolled in by Microsoft | Environment Availability | Medium — on the Hetzner VM image specifically, WebView2 may or may not be pre-installed. If absent, install manually as Phase 7 measurement setup (not part of the shipped installer — that's Phase 10). |

**User confirmation needed for:** A2 (UX fallback), A3 (memory optimization availability). A1/A5/A6 are verifiable mechanically. A4 is Claude's discretion. A7 is a VM-provisioning detail.

## Open Questions

1. **Left-click toggle pattern on `fyne.io/systray` v1.12.0 Windows**
   - What we know: `RunWithExternalLoop` is the integration API; menu click handlers use `ClickedCh`. Left-click on the tray icon itself is tracked as a separate concern.
   - What's unclear: Whether v1.12.0's `OnClick` hook fires on left-click on Windows, or only on default-action (double-click / menu-item-0).
   - Recommendation: Wave 0 spike — 50-line standalone Go program with fyne.io/systray, log any click event. 30 minutes. Determines whether D-06 UX can be met literally or needs adjustment.

2. **Raise-existing-window transport**
   - What we know: Second `wails.Run` will fail with mutex-already-exists; we want to signal the running instance to `WindowShow`.
   - What's unclear: Simplest transport — `FindWindow` by title + `WM_USER` custom message, or a named pipe, or a shared event.
   - Recommendation: `FindWindow` by the Wails window title is simplest; test with Wails' default title behavior. If fragile (e.g., title changes with locale), use a named event the running instance waits on.

3. **Internal package shape: one module or nested module**
   - What we know: Both shapes work with go.work.
   - What's unclear: Which shape minimizes replace-directive noise and keeps `go test ./...` clean in each workspace.
   - Recommendation: Try option 1 (`internal/mapi` as its own module) first; fall back to a root module if import paths get gnarly.

4. **CoreWebView2MemoryUsageTargetLevel exposure in Wails v2.12.0**
   - What we know: The API exists in WebView2; Wails v2 wraps WebView2 options.
   - What's unclear: Whether the specific `MemoryUsageTargetLevel` field is plumbed through Wails options or requires a patch / custom build.
   - Recommendation: Check `windows.Options` struct in Wails v2.12.0 source during the Pattern 1 spike. If not exposed, accept lazy-init alone and document the gap.

5. **RDS VM provisioning — WebView2 presence**
   - What we know: Hetzner Windows Server 2022 image ships stock; WebView2 ships with modern Windows Update.
   - What's unclear: Whether a fresh Hetzner image has WebView2 or whether it needs manual install.
   - Recommendation: As part of D-02 provisioning, run the Evergreen Bootstrapper once on the VM (non-automated — this is measurement setup, not product installer). Document the presence/absence of WebView2 pre-bootstrap.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Go | Native-host (existing) + new `src/app/` backend | ✓ (dev machine) | 1.21 currently; must bump to 1.23 | — |
| Node | Wails frontend build + existing extension + changesets | ✓ (dev machine) | 18+ `[VERIFIED: package.json engines-equivalent via npm scripts]` | — |
| Wails CLI | Scaffolding + build | ✗ (needs install) | v2.12.0 | `go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0` |
| MinGW (gcc/g++) | C++ interceptor + CGO for Go (Wails + fyne.io/systray require CGO) | ✓ (existing requirement) | per existing build | — |
| CMake 3.16+ | C++ interceptor build | ✓ (existing requirement) | — | — |
| WebView2 Runtime | Wails app at runtime (not build) | ✓ on modern Windows 10/11 dev boxes | Evergreen (auto) | If absent on Hetzner VM: run Evergreen Bootstrapper manually as measurement-setup step |
| Hetzner Windows Server 2022 VM | RAM measurement (D-02) | ✗ (must be provisioned) | — | None — the VM is the measurement instrument |
| RDP client (mstsc.exe or equivalent) | Connecting to Hetzner VM as 5–10 concurrent users | ✓ (Windows built-in) | — | — |
| Windows Task Manager / `Get-Process` / PerfMon | Reading Private Working Set | ✓ (Windows built-in) | — | — |
| Pester 5 | Optional — D-03 measurement automation | ✓ (shipped with Windows 10/11 or installable via PSGallery) | 5.x | Manual measurement + documented procedure acceptable per Claude's discretion |

**Missing dependencies with no fallback:**
- Hetzner Windows Server 2022 VM — must be provisioned before measurement. Account for cost (hourly; plan to destroy post-measurement).

**Missing dependencies with fallback:**
- Wails CLI — trivial `go install` (documented above).
- WebView2 Runtime on the VM — if absent, run Evergreen Bootstrapper (2 MB download + silent install) during VM provisioning step.

## Security Domain

Phase 7 has **minimal** security surface — no network calls, no credential handling, no user input parsing beyond existing email JSON validation (carried forward unchanged from v2.x). Config has `security_enforcement` absent (treat as enabled) so this section is included, but most categories do not apply in this phase.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | Phase 8 (OAuth) |
| V3 Session Management | no | Phase 8 (token storage) |
| V4 Access Control | no | Single-user desktop app; no multi-user roles |
| V5 Input Validation | partial | Existing `validateMailMessage()` preserved unchanged during extraction to `internal/mapi/`; fuzz-tests (if any) carry forward |
| V6 Cryptography | no | No crypto in Phase 7. Phase 8 introduces DPAPI-via-go-keyring. |
| V7 Error Handling & Logging | yes | Log to file only (no PII in logs); align with existing `[INFO]`/`[ERROR]` prefixed RFC3339 pattern; do not log email bodies |
| V9 Communications | no | No network in Phase 7 |
| V10 Malicious Code | yes | Dependency choices all vetted upstream (STACK.md); no unknown-provenance libs added in Phase 7 |
| V12 Files & Resources | yes | Watching `%TEMP%\go-mapi\`, a per-user directory — existing behavior, no change |
| V14 Configuration | yes | No hardcoded secrets (none exist to hardcode in Phase 7); Go 1.23 pin documented; CGO required and accepted |

### Known Threat Patterns for Wails v2 + Windows

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Window-title spoofing to fool `FindWindow`-based single-instance raise | Spoofing | Use a uniquely-named kernel event or named pipe instead of title-matching, or add a custom class name to the Wails window |
| Malicious JSON in `%TEMP%\go-mapi\` (attacker writes crafted file) | Tampering | Existing `validateMailMessage()` runs before any action; validation moves bad files to `errors/` — carry forward unchanged |
| Path traversal in email fixture filenames | Tampering | Existing watcher reads by `os.ReadDir` and resolves with `filepath.Join` within fixed root — preserved in extraction |
| WebView2 renderer exploit loading remote content | Elevation | Wails embeds assets from `embed.FS`; no remote URLs loaded. Confirm no `http://`/`https://` iframes in Svelte templates. |
| Log file privilege escalation on shared machine (RDS) | Information Disclosure | Write app log to `%APPDATA%\go-mapi\` (per-user ACL) not `%PROGRAMDATA%`; document if `%TEMP%` is chosen. |
| CGO supply chain (fyne.io/systray, Wails) | Tampering | Pin versions exactly in go.mod; verify via `go mod verify` in CI; don't auto-update CGO deps |

**No new security-critical code in Phase 7.** The extraction preserves existing validation + normalization; the shell has no external surface beyond the tray (local user-only) and the WebView2 window (local user-only, embedded assets only).

## Sources

### Primary (HIGH confidence)
- `.planning/research/SUMMARY.md` — phase-structure rationale; stack consensus; RAM gate framing — 2026-04-12
- `.planning/research/STACK.md` — all version and library decisions with official-doc citations — 2026-04-12
- `.planning/research/ARCHITECTURE.md` §Window Lifecycle, §Single-instance, §Event channels — patterns and anti-pattern overrides — 2026-04-12
- `.planning/research/PITFALLS.md` §1, §7, §11 — concrete Phase 7 pitfalls with mitigations — 2026-04-12
- `.planning/phases/07-wails-shell-ram-gate/07-CONTEXT.md` — all locked decisions (D-01..D-12) — 2026-04-13
- `src/native-host/go.mod`, `src/native-host/watcher.go`, `package.json` — `[VERIFIED]` live codebase state
- Microsoft: [WebView2 distribution](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution), [WebView2 process model](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/process-model), [message-only windows](https://devblogs.microsoft.com/oldnewthing/20171218-00/?p=97595)

### Secondary (MEDIUM confidence)
- `github.com/wailsapp/wails/discussions/4514` — `getlantern/systray` conflict; Wails v2 systray stance — cited via STACK.md
- `pkg.go.dev/fyne.io/systray` v1.12.0 entry — `RunWithExternalLoop` API shape — cited via STACK.md
- `.planning/research/FEATURES.md`, `.planning/research/CONVENTIONS.md` — feature dependency graph; Go conventions

### Tertiary (LOW confidence)
- Assumption A2 (fyne.io/systray left-click handler on Windows) — must be confirmed by Wave 0 spike
- Assumption A3 (Wails v2.12.0 exposing `MemoryUsageTargetLevel`) — must be confirmed by reading Wails options struct at implementation time
- Assumption A7 (WebView2 presence on fresh Hetzner Windows Server 2022) — confirm during VM provisioning

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all versions upstream-verified 2026-04-12 with official sources; one-day-old research
- Architecture: HIGH for Wails lifecycle, MEDIUM for WM_QUERYENDSESSION hidden-HWND wiring (documented pattern, project-untested)
- Pitfalls: HIGH — PITFALLS.md §1/§7/§11 are dense and specific
- RAM outcome: UNKNOWN until measured — that's the gate
- Frontend scaffold: HIGH for template choice (Svelte 5 + TS), MEDIUM for zero-runtime bundle shape (depends on what Svelte 5 features are used)

**Research date:** 2026-04-13
**Valid until:** 2026-05-13 (30 days — stack is stable; longer staleness risks Wails v2 patch releases slipping past)
