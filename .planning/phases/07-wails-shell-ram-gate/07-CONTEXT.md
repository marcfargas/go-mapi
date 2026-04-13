# Phase 7: Wails Shell + RAM Gate - Context

**Gathered:** 2026-04-13
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver a minimal Wails desktop app that runs on Windows with a system tray icon, a closable (hides-to-tray) main window, single-instance enforcement, clean logoff handling, and the existing `%TEMP%\go-mapi\` file watcher folded in. Measure per-instance RAM under RDS-like conditions and document the result. This phase is a **gate** — no OAuth, no Gmail draft logic, no toasts, no installer work. If the RAM measurement passes, Phases 8–11 proceed as planned; if it fails, work halts for re-evaluation.

Covers requirements: SHELL-01, SHELL-02, SHELL-03, SHELL-04, SHELL-05, SHELL-06, SHELL-07, QUAL-01, QUAL-02, QUAL-04.

</domain>

<decisions>
## Implementation Decisions

### RAM Measurement Methodology
- **D-01:** Pass/fail metric is **Private Working Set** (Task Manager "Memory (private working set)"). Rationale: excludes shared WebView2/Edge runtime pages — fair for RDS where many instances share the runtime. Total Working Set would overcount; Commit Size includes paged-out memory and does not reflect real pressure.
- **D-02:** RDS simulation: spin up a **Hetzner Windows Server 2022 VM** with 5–10 concurrent user sessions (real HDESKTOP isolation). Cheaper alternatives (N instances under one workstation user) under-report RDS cost and are rejected.
- **D-03:** Measurement protocol: three samples per session — **cold start**, **5-min idle**, and **after first window toggle** (post-WebView2 init). Run 3 iterations per scenario, average. This captures startup cost, steady state, and post-init steady state — all three matter for the lazy-init decision.
- **D-04:** Gate threshold is **≤ 80 MB private working set per session, measured at 5-min idle (post-WebView2-init)**. 30 MB remains a documented stretch goal; not a pass criterion.

### Main Window Content (Phase 7 scope)
- **D-05:** Main window renders a **minimal live queue list** (sender, subject, timestamp; no attachment count) fed by Wails events from the folded-in watcher. **No per-email action buttons** — Create-draft/Dismiss are Phase 9. Rationale: SHELL-06 folds the watcher in anyway, so event-pipeline plumbing lands here; giving Svelte something real to render exercises the RAM path (empty windows under-measure).
- **D-06:** Window toggle behavior: left-click tray icon = show + focus; left-click when visible = hide. Standard Windows tray pattern (OneDrive/Teams). Hide never quits; only the Quit menu item or Windows logoff quits.

### Codebase Structure Migration
- **D-07:** Introduce a **new `src/app/` workspace alongside the existing `src/native-host/`** in Phase 7. Do not move or rename `src/native-host/` yet. Keeps native-host buildable for rollback and keeps the RAM-gate phase focused; the full absorb described in research ARCHITECTURE.md happens after Phase 7 passes.
- **D-08:** Shared Go code (watcher, validator, gmail client, protocol types) is **extracted to an `internal/` Go package** (suggested name `internal/mapi` — planner decides final structure) imported by both `src/native-host/` and `src/app/`. Single source of truth; no duplication. Extraction happens in Phase 7 as prerequisite to SHELL-06.
- **D-09:** `src/app/` is a new changesets workspace. Svelte frontend lives under `src/app/frontend/` per research ARCHITECTURE.md. Planner to verify `go.work` layout + changesets config.

### Tray Menu + Icon Assets
- **D-10:** Phase 7 tray right-click menu: **Show + Quit only**. Explicit deviation from SHELL-02 wording ("Show / Pause watching / Quit") — Pause-watching is deferred to Phase 9 when queue actions exist. Phase 9 CONTEXT must pick this up and complete SHELL-02.
- **D-11:** Ship **two icon variants** in Phase 7: **idle + error**. Error covers watcher init failure and WebView2 missing / bootstrap failure. Has-queue variant is deferred to Phase 9 (nothing to reflect yet). Light/dark variants are Claude's discretion if time permits.

### RAM Gate Failure Contingency
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

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project-level specs
- `.planning/PROJECT.md` — v3.0 milestone scope, RAM constraint origin, clean-break migration posture
- `.planning/REQUIREMENTS.md` §Shell + §Quality Gates — SHELL-01..07, QUAL-01, QUAL-02, QUAL-04 acceptance criteria
- `.planning/ROADMAP.md` §Phase 7 — goal statement and success criteria

### Research (stack + patterns locked here)
- `.planning/research/SUMMARY.md` — executive summary, confidence ratings, phase-structure rationale, RAM gate framing
- `.planning/research/STACK.md` — Wails v2.12.0 + fyne.io/systray v1.12.0 RunWithExternalLoop pattern; Go 1.23 pin; Svelte 5 choice
- `.planning/research/ARCHITECTURE.md` — App struct, window lifecycle (`Hidden:true`, `HiddenOnTaskbar:true`, `WindowClosing` → hide), event channel names, named mutex pattern, hidden message-only HWND for `WM_QUERYENDSESSION`. Note: recommendation to use Wails v3 alpha is overridden — use v2.12.0 per SUMMARY consensus.
- `.planning/research/PITFALLS.md` §1 (RAM), §7 (tray race), §11 (Go version) — critical pitfalls active in Phase 7
- `.planning/research/FEATURES.md` — system tray table stakes definition; feature dependency graph

### Codebase (existing patterns to preserve)
- `.planning/codebase/ARCHITECTURE.md` — current three-tier structure and IPC model
- `.planning/codebase/STRUCTURE.md` — `src/native-host/` layout that will be extracted to `internal/`
- `.planning/codebase/CONVENTIONS.md` — Go naming, error handling, logging conventions to carry forward
- `.planning/codebase/STACK.md` — current toolchain and build pipeline
- `.planning/codebase/TESTING.md` — existing test coverage map; `internal/` extraction must preserve these tests

### Seed decision
- `.planning/notes/2026-04-12-architecture-reeval-wails.md` — original Wails pivot rationale; why WebView2 vs Electron/Fyne/Tauri

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `src/native-host/watcher.go` — `EmailWatcher` with fsnotify debounce (500ms), AV-lock retry (3×200ms), content-hash IDs, in-memory map. Must be extracted to `internal/` and reused by the Wails App struct; replace its current `NativeMessaging` output hook with a Wails-event callback (`queue-update`).
- `src/native-host/protocol.go` — `MailMessage` struct + `validateMailMessage()` + address normalization. Pure data + validation; moves cleanly to `internal/`.
- `src/native-host/gmail.go` — not used in Phase 7 (OAuth is Phase 8) but must be in the extraction batch to avoid a second migration later. Add the 30s timeout + 3-retry backoff (PITFALLS #12) when Phase 8 touches it, not here.
- `tests/protocol-fixtures/` — shared JSON fixtures; extraction must keep these accessible from the new test locations.

### Established Patterns
- Go logging: timestamped RFC3339 + `[INFO]`/`[ERROR]` prefix, file-based in `%TEMP%\go-mapi\native-host.log`. Phase 7 Wails app should follow — likely `%TEMP%\go-mapi\app.log` or `%APPDATA%\go-mapi\app.log`.
- Error wrapping with `%w` verb; lowercase error strings.
- `sync.RWMutex` + `chan struct{}` done-signal for graceful goroutine shutdown — pattern to preserve when watcher folds into Wails lifecycle.
- Changesets monorepo: each workspace has its own `package.json` + version track. `src/app/` must be added as a new workspace per v2.1.0 Phase 6 convention.

### Integration Points
- **Wails `OnStartup`**: call `systray.RunWithExternalLoop(...).start()`; spawn named-mutex check; register hidden message-only HWND for `WM_QUERYENDSESSION`; initialize lazy WebView2 (do not force-load until window first shown).
- **Wails `OnShutdown`**: call `systray.RunWithExternalLoop(...).end()`; stop watcher; close mutex handle.
- **`WindowClosing` callback**: intercept, call `runtime.WindowHide()`, return `true` to prevent actual close.
- **Watcher → frontend**: watcher emits events → App struct → `runtime.EventsEmit(ctx, "queue-update", payload)` → Svelte subscribes.
- **MAPI DLL → watcher**: unchanged. C++ still writes JSON to `%TEMP%\go-mapi\`. Phase 7 does not touch `src/interceptor/`.

</code_context>

<specifics>
## Specific Ideas

- Hetzner Windows Server VM for the RAM measurement — Marc has Hetzner access (nexus is already a Hetzner Linux box); a short-lived Windows Server 2022 VM for the gate is acceptable hourly spend.
- Tray-toggle UX modeled on OneDrive / Teams (click to show, click-when-visible to hide).
- Phase 9 CONTEXT must complete SHELL-02 (add Pause-watching) and SHELL-07 (add has-queue icon variant) — these are intentionally deferred here.

</specifics>

<deferred>
## Deferred Ideas

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

</deferred>

---

*Phase: 07-wails-shell-ram-gate*
*Context gathered: 2026-04-13*
