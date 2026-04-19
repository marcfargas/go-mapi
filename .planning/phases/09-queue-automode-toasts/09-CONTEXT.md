# Phase 9: Queue, Automode + Toasts - Context

**Gathered:** 2026-04-19
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver the Phase 9 feature surface on top of the Wails shell + OAuth Phase 8 shipped:

1. **Queue UI with per-email actions** — Main window lists pending emails (sender, subject, attachment count, timestamp). Inline `Create draft` and `Dismiss` buttons per row. Live updates via the existing `queue-update` event (no polling).
2. **Manual / Auto-draft mode toggle** — Two-state segmented control in the main window header. Persists across restarts in `%APPDATA%\go-mapi\settings.json`. Auto-draft runs in a Go goroutine and processes new arrivals whether the window is visible or hidden.
3. **Automode failure handling** — Failed auto-drafts stay in the queue with an inline error badge and trigger an error toast; a re-auth / network / Gmail-error category drives the tooltip text. No auto-retry. On `invalid_grant`, rows fall back to manual; the existing ReAuthBanner surfaces; no retroactive backlog draining after re-auth.
4. **Windows toast notifications** — New queued emails fire a toast (sender + subject + attachment count, no body text). Toast action buttons trigger Create draft / Dismiss without requiring the main window. Toasts removed from Action Center when the underlying email is processed (NOTIF-05). AUMID registration: Phase 10 installer owns prod; Phase 9 ships a `scripts/register-dev-aumid.ps1` helper for `wails dev` so toast + AC persistence can be exercised end-to-end.
5. **Pause watching tray menu item** (Phase 7 D-10 deferred here) — Suppresses toasts and halts automode; watcher keeps running so queue still accrues. Session-only state, resets on restart.
6. **Has-queue tray icon variant** (Phase 7 D-11 deferred here) — Ships `tray-has-queue.ico` as a third static variant alongside idle + error. No runtime badge composition.
7. **Phase 8.1 test-hygiene pass** — WR-01, WR-02, WR-03 (recorded in `.planning/STATE.md`) are folded into Phase 9 as a dedicated plan. Closes develop-branch CI to green.

Covers requirements: QUEUE-01, QUEUE-02, QUEUE-03, QUEUE-04, QUEUE-05, QUEUE-06, QUEUE-07, NOTIF-01, NOTIF-02, NOTIF-03, NOTIF-04 (dev-side only; install-time registration is Phase 10), NOTIF-05. Also completes SHELL-02 (Pause-watching) and SHELL-07 (has-queue icon) — both deferred to Phase 9 in the Phase 7 CONTEXT.

**Out of scope for Phase 9 (belongs in later phases):**
- Production AUMID + Start Menu shortcut registration (Phase 10 INST-04)
- WebView2 bootstrap, installer packaging, uninstall (Phase 10)
- Autoupdate check + notify UX (Phase 11 REL-03/REL-04)
- Auto-send mode (locked out of v3.0 per PROJECT.md Out of Scope — irreversibility risk)
- Multi-account / per-email mode override (PROJECT.md Out of Scope — v4+)
- Bulk row actions (select multiple) — PROJECT.md Out of Scope
- Row expand-to-detail (click-to-expand) — explicitly deferred (see D-03); may revisit in a later UX phase
- Retroactive auto-draft of backlog after re-auth (explicitly rejected — see D-10)

</domain>

<decisions>
## Implementation Decisions

### Queue Row Rendering (QUEUE-01, QUEUE-02, QUEUE-03)
- **D-01:** `Create draft` and `Dismiss` buttons are **inline and always visible** on every row. No hover-to-reveal, no expand-to-show.
- **D-02:** Attachment count renders as `📎 <number>` inline; **hidden entirely when count is zero**. Matches Gmail/Outlook convention; keeps the 90%-no-attachments case uncluttered.
- **D-03:** Row body is **inert** — clicking anywhere except a button does nothing. Keyboard: row is focusable (tabindex=0) but `Enter` on the row does nothing; action buttons have their own focus stops. No row-expand detail view in Phase 9.
- **D-04:** Post-draft feedback is **conditional on window visibility**:
  - If main window is visible + focused → row fades with a `✓ Drafted` flash (~1.5s target, CSS transition), then MarkProcessed removes the file and the row disappears on the next `queue-update`.
  - If main window is hidden/minimized → Windows toast fires (`Draft created: <subject>`), row removes silently.
  - Applies to both manual row-button clicks and automode auto-drafts.

### Toast Stack + AUMID (NOTIF-01..05)
- **D-05: Toast library choice deferred to researcher.** Hard constraints the researcher must honor:
  - **No PowerShell-per-toast.** The `go-toast/toast` PowerShell-wrapper pattern is rejected on latency grounds (≈200 ms cold PowerShell startup per toast).
  - **Verify Wails v2.12.0 does not already ship a toast helper** (native or bundled addon) before picking a third-party library. Wails v3 has proposed notification APIs — confirm what, if anything, v2.12.0 exposes.
  - **RDS/RDP is the primary deployment target.** Multi-session isolation materially affects candidate libraries — anything relying on per-machine COM registration or global listeners must be validated (or rejected) against RDS semantics.
- **D-06: Dev-time AUMID via helper script.** Ship `scripts/register-dev-aumid.ps1` that creates an HKCU Start Menu shortcut with a dev AUMID (suggested `com.marcfargas.gomapi.dev`). One-time run per dev machine unblocks Action Center persistence during `wails dev`. Phase 10 installer owns the prod AUMID + shortcut registration (INST-04). Prod AUMID suggestion: `com.marcfargas.gomapi` — planner confirms or adjusts.
- **D-07: Toast action-button activation deferred to researcher.** Requirement: NOTIF-03 — toast action buttons trigger Create draft / Dismiss without requiring the main window to open. Candidate paths: (a) foreground-activation + hide-to-tray (brings app forward, handles action, re-hides); (b) COM background activator (Windows launches a COM class without showing a window). RDS/RDP primacy (D-05 constraint) applies — the researcher must validate the chosen path survives multi-session isolation.
- **D-08:** NOTIF-05 removal scheme: **`tag = email-id`** (content-hash from watcher), **`group = "go-mapi-queue"`**. On draft success or dismiss, call `ToastNotifier.History.Remove(tag, group)` so only the processed email's toast leaves Action Center. The shared group also enables Win10/11 auto-collapse of multiple pending toasts under a single `go-mapi` header.

### Automode Failure + Signed-Out Handling (QUEUE-05, QUEUE-06)
- **D-09:** Auto-draft failure presents as:
  - Inline red `!` badge on the failed row with a hover-tooltip showing the error category (`Signed out` / `Network error` / `Gmail error`).
  - One error toast per failure with the same category text (fires regardless of window visibility — errors always need attention).
  - **No auto-retry.** Research ARCHITECTURE.md §4.5 + FEATURES.md §3 explicitly reject silent retries (duplicate-draft risk, loop risk on persistent OAuth failure). User must manually click `Create draft` on the failed row.
- **D-10:** When `invalid_grant` fires during automode:
  - Affected rows stay in the queue with the row badge + `Signed out` tooltip.
  - The existing ReAuthBanner surfaces (Phase 8 D-05 plumbing already emits `auth-changed {authenticated:false, invalidGrant:true}`).
  - One summary toast fires: `Sign-in expired — emails queued for manual review`.
  - After successful re-auth, **new arrivals resume automode** but pending rows **stay manual** — no retroactive backlog draining. Rationale: rows queued hours ago during a session the user may no longer remember should not auto-draft without explicit review.
- **D-11: Toast suppression while window is visible + focused.**
  - **Arrival toasts** are suppressed when the main window is visible and focused — the live list update via `queue-update` already signals the arrival; double-signalling is noise.
  - **Draft-success toasts** follow the same rule: window visible → in-window row flash only; hidden → toast.
  - **Error toasts always fire** regardless of window state.

### Mode Toggle (QUEUE-04)
- **D-12:** Mode toggle lives in the **main window header** next to SignedInHeader. Two-state segmented control: `Manual` / `Auto-draft`. No duplicate control in the tray menu — tray tooltip reflects the active mode (see D-17). Rationale: keeps the surface area smaller; tray menu stays lightweight (Show / Pause / Quit).
- **D-13:** Mode state persists in **`%APPDATA%\go-mapi\settings.json`**. Default = `"manual"`. Initial Phase 9 fields: `{ "mode": "manual" | "auto-draft" }`. Atomic-write pattern (write to `settings.json.tmp` + `os.Rename`) to avoid torn writes on crash — planner confirms exact pattern (and whether to use `go-internal/lockedfile` or stdlib-only).

### Pause-Watching + Has-Queue Icon (SHELL-02 completion, SHELL-07 completion)
- **D-14: Pause scope = suppress toasts + halt automode; watcher keeps running.**
  - The fsnotify watcher stays active so the queue still accrues; user can open the window at any time and see pending emails + manually act.
  - Toasts are muted while paused.
  - Auto-draft goroutine does not consume queued emails while paused.
  - Matches Slack's "Pause notifications" mental model. Safer than stopping the watcher (which would risk on-disk JSON accumulation + AV-lock issues).
- **D-15: Pause is session-only** — resets on every app start. Not persisted. Rationale: prevents the "I paused a month ago and forgot" failure mode where users silently miss every email. Paused state lives in a `sync.Mutex`-guarded bool on the App struct, not in settings.json.
- **D-16: Three static tray icon variants** — `tray-idle.ico`, `tray-has-queue.ico` (new in Phase 9), `tray-error.ico`. No runtime image composition / badge numbering. Icon priority when multiple states apply (highest wins): **error > paused-visual > signed-out-visual > has-queue > idle**. Planner writes the explicit state table in PLAN.md. Planner decides whether "paused" and "signed-out" need their own icon or just tooltip-only differentiation — default assumption: tooltip-only (keeps icon count to three) unless research/visual-design recommends otherwise.
- **D-17: Tray tooltip format** — `go-mapi — <mode-segment> — N pending`. Mode-segment values: `Manual`, `Auto-draft`, `Paused`, `Signed out`. Examples:
  - `go-mapi — Auto-draft — 3 pending`
  - `go-mapi — Paused — 2 pending`
  - `go-mapi — Signed out — 1 pending`
  - `go-mapi — Manual — 0 pending`
  Error state overrides mode segment: `go-mapi — watcher stopped` (existing Phase 7 `SetTrayError` copy).

### Test Hygiene (Phase 8.1 Handoff)
- **D-18:** WR-01, WR-02, WR-03 (recorded in `.planning/STATE.md` and Phase 8.1 `08.1-REVIEW.md`) are **folded into Phase 9 as a dedicated test-hygiene plan** — not deferred to a separate inserted phase. Planner sequences it as an early plan so subsequent plan work runs against a green CI. Scope:
  - **WR-01:** `TestAuthCodeURLHasPKCE` is `t.Parallel`-unsafe because it mutates the `authEndpointOverride` package variable. Fix: remove `t.Parallel()` from the test, or restructure the override as an injected dependency (planner picks).
  - **WR-02:** Bootstrap-auth tests leak a goroutine to the real Google userinfo endpoint (network call under `-race`). Fix: inject `userinfoEndpointOverride` at the test boundary and use `httptest.Server` stubs (Phase 8.1 D-12 pattern).
  - **WR-03:** `TestDispatcherCoalesces` at `src/app/watcher_bridge_test.go:93` (origin commit `36ca9e8` — Phase 7) flakes on windows/amd64 under `-race`. Current assertion `count == 1` is over-tight; the 1-slot `pending` channel's legal outcomes under burst load are `count ∈ {1, 2}` depending on whether the dispatcher drains the first value before `OnQueueChanged` completes its burst. Fix: either loosen the assertion (`count >= 1 && count <= len(burst)`), redesign the coalesce guarantee, or add a deterministic sync point. Planner picks based on intent preservation.
  - Rationale: STATE.md already commits to fixing these in the "Phase 9 test-hygiene pass"; keeping them inside Phase 9 honours that plan and closes develop-branch CI.

### Claude's Discretion
- Exact row-fade duration (~1.5s target); `✓ Drafted` flash copy; CSS transition curve — UI-spec / planner.
- Error-toast copy and error-badge tooltip phrasing — keep short, English, pragmatic; match project voice.
- Whether to emit an `auto-draft-result` event for both success and failure, or only failure (frontend can re-query queue via existing `queue-update` for success); planner picks based on frontend state-sync ergonomics.
- Draft-success toast content: `Draft created: <subject>` with optional `Open in Gmail` link (FEATURES.md LOW-complexity differentiator) — planner decides if the Gmail draft URL is reliably constructable and worth the plumbing for v3.0.
- Whether draft-success toasts carry action buttons (probably not — dismissible-only is fine); researcher can advise if chosen library makes zero-button toasts trivial.
- AUMID string values — suggestion `com.marcfargas.gomapi` for prod, `com.marcfargas.gomapi.dev` for dev; planner confirms.
- `tray-has-queue.ico` visual design — planner/UI-spec picks color + glyph to distinguish from idle at 16×16. Match existing icon style.
- Pause-menu label wording — `Pause watching` (SHELL-02 wording) vs `Pause notifications` (truer to D-14 behavior); UI-spec picks. If kept as `Pause watching`, add hover tooltip explaining "Silences toasts and auto-draft; queue still collecting".
- Mode-toggle visual — segmented control vs toggle-switch vs radio group — UI-spec picks.
- `App.PauseWatcher()` / `App.ResumeWatcher()` binding signature (Wails-exposed vs tray-internal-only) — planner picks based on whether frontend ever needs to read paused state beyond tooltip.
- settings.json location — `%APPDATA%\go-mapi\settings.json` (preferred; matches log location Phase 7 chose) vs `%LOCALAPPDATA%`; planner confirms.
- settings.json atomic-write pattern (tmp + rename is default) — planner confirms; consider `crypto/rand` for tmp suffix to avoid collisions during rapid saves.
- Exact tray icon priority table when multiple states overlap — planner writes it (my default in D-16 is one interpretation; planner refines).
- Row focus outlines + keyboard-accessibility details — UI-spec owns.
- Whether to ship two sets of ICO sizes (16×16 + 32×32 for HiDPI) — Claude's Discretion in Phase 7 deferred; Phase 9 ships what RDS needs, planner picks.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project-level specs
- `.planning/PROJECT.md` — v3.0 milestone scope, privacy baseline (no retention, no body text in toasts), Out-of-Scope list (Auto-send, multi-account, per-email mode override, bulk actions)
- `.planning/REQUIREMENTS.md` §Queue, Actions & Automode — QUEUE-01..07 acceptance criteria
- `.planning/REQUIREMENTS.md` §Notifications — NOTIF-01..05 (with NOTIF-04 dev-side in Phase 9, install-time in Phase 10)
- `.planning/REQUIREMENTS.md` §Quality Gates — QUAL-03 (no telemetry, no content retention)
- `.planning/ROADMAP.md` §Phase 9 — goal + five success criteria

### Upstream phase context (decisions carry forward)
- `.planning/phases/07-wails-shell-ram-gate/07-CONTEXT.md` — D-05 (minimal queue list pattern), D-10 (Pause-watching deferred to Phase 9 — completed here), D-11 (has-queue icon deferred to Phase 9 — completed here), tray `LockOSThread` pattern, Wails event-channel naming
- `.planning/phases/07-wails-shell-ram-gate/07-VERIFICATION.md` — RAM gate PASS; Phase 9 feature work does not regress RAM budget (validate in review)
- `.planning/phases/08-oauth-credentials/08-CONTEXT.md` — D-04 (watcher keeps running while signed out), D-05 (re-auth banner wiring — reused here), D-07 (draft button disabled with `Sign in first` tooltip when unauth'd — extended to Phase 9 row buttons), D-11 (keyring service=`go-mapi` user=`oauth-tokens`), D-13 (refresh proactive + reactive via `MakeAuthenticatedGmailCall`), D-14 (GmailClient stays stateless)
- `.planning/phases/08.1-post-pivot-cleanup-and-test-coverage-review/08.1-CONTEXT.md` — D-05 (risk-based gap filling, applies to new Phase 9 code), D-11 (KeyringStore interface seam — reuse for settings-store abstraction if applicable), D-12 (httptest.Server pattern for Gmail HTTP tests — reuse for automode auth-path tests)

### Phase 8.1 handoff — test hygiene (see D-18)
- `.planning/STATE.md` — WR-01 / WR-02 / WR-03 descriptions + origin references + acceptance that develop CI stays RED until Phase 9 fixes them
- `.planning/phases/08.1-post-pivot-cleanup-and-test-coverage-review/08.1-REVIEW.md` — formal warnings with line numbers
- `src/app/watcher_bridge_test.go:93` — WR-03 flake site (`TestDispatcherCoalesces`)
- `src/app/auth_test.go` — WR-01 + WR-02 locations (planner to scan for `TestAuthCodeURLHasPKCE` + bootstrap-auth tests)

### Research (patterns locked here)
- `.planning/research/FEATURES.md` §1 System Tray — tooltip format, icon-state expectations
- `.planning/research/FEATURES.md` §2 Toast Notifications — AUMID requirement, tag/group scheme, no-body-text anti-feature, action-button patterns, NOTIF-05 Action Center cleanup
- `.planning/research/FEATURES.md` §3 Automode — mode toggle location guidance, fallback-to-manual-on-failure requirement, no-auto-retry principle, per-session persistence
- `.planning/research/ARCHITECTURE.md` §3 Event Channels — `queue-update`, `auth-changed`, `draft-created` event names + payloads (note: Phase 9 may add `auto-draft-result`)
- `.planning/research/ARCHITECTURE.md` §4.5 Auto-Mode Loop — goroutine pattern sketch (planner adapts to current `watcherBridge` shape)
- `.planning/research/ARCHITECTURE.md` §5 OAuth Token Storage and Refresh — refresh algorithm + `MakeAuthenticatedGmailCall` integration point for automode
- `.planning/research/ARCHITECTURE.md` §6 Tray vs Window Split — badge vs static-variant tradeoff (Phase 9 chose static variant per D-16)
- `.planning/research/PITFALLS.md` §5 — no EventsEmit on hot watcher paths (reinforced by existing `src/app/watcher_bridge.go` 1-slot pending channel design)

### Codebase (existing patterns to extend)
- `src/app/app.go` — App struct bindings (`GetQueue` already exists), `shutdownCtx` drain pattern, `watcherBridge` wiring, `intentionalQuit atomic.Bool`
- `src/app/auth.go` — `MakeAuthenticatedGmailCall(ctx, fn)` (refresh + 401 retry + invalid_grant emit), `AuthStatus` type, `emitAuthChanged`, `GetAuthStatus` binding
- `src/app/tray.go` — `startTray` pattern with `LockOSThread`, `SetTrayError` + `SetTrayIdle` helpers (extend with `SetTrayHasQueue`), tray-menu click goroutine loop
- `src/app/watcher_bridge.go` — 1-slot `pending chan struct{}` with coalesce-on-burst, dispatcher goroutine pattern; **WR-03 lives here at line 93**
- `src/app/singleinstance.go`, `src/app/sessionend.go`, `src/app/logging.go`, `src/app/paths.go` — unchanged; reference for conventions
- `internal/mapi/watcher.go` — `EmailWatcher.Snapshot()`, `MarkProcessed(id)`, `Delete(id)`, existing `WatcherCallback` interface
- `internal/mapi/gmail.go` — stateless `GmailClient.CreateDraft(msg)` — Phase 9 wraps via `MakeAuthenticatedGmailCall`
- `internal/mapi/protocol.go` — `MailMessage` + attachments + recipient normalization
- `src/app/frontend/src/App.svelte` — current shell with SignInScreen / PreAuthModal / ReAuthBanner / SignedInHeader + minimal queue list; Phase 9 extends this (row actions, attachment count, mode toggle in header)
- `src/app/frontend/src/lib/queue.ts` — `fetchQueue` + `subscribeQueue('queue-update', ...)` — already handles the null→[] fallback (WR-03-era regression guard)
- `src/app/frontend/src/lib/auth.ts` — `fetchAuthStatus` + `subscribeAuth` + `signIn` / `signOut` + `hasSeenPreAuthExplainer` — Phase 9 reads auth status to toggle row-button enabled state (D-07 from Phase 8)
- `src/app/frontend/src/lib/components/*.svelte` — four existing components; Phase 9 adds ModeToggle + QueueRow + possibly AutoDraftFailureBadge

### Codebase conventions
- `.planning/codebase/CONVENTIONS.md` — Go naming (PascalCase exported, camelCase unexported), error wrapping with `%w`, lowercase error strings, `sync.RWMutex` + `chan struct{}` done-signal pattern
- `CLAUDE.md` (project root) — v3.0 Wails-era conventions, Svelte 5 runes (`$state`, `$props`, `$derived`), Vitest + @testing-library/svelte testing pattern, commit-message style `type(NN): description`

### External specs + library refs
- `https://learn.microsoft.com/en-us/windows/apps/design/shell/tiles-and-notifications/adaptive-interactive-toasts` — toast XML schema (content + actions + audio)
- `https://learn.microsoft.com/en-us/windows/apps/design/shell/tiles-and-notifications/send-local-toast-desktop-cpp-wrl` — unpackaged-app toast + COM activator pattern
- `https://learn.microsoft.com/en-us/windows/win32/shell/appids` — AUMID registration (AppUserModelID property on Start Menu shortcut)
- `https://pkg.go.dev/fyne.io/systray` — systray API (already in use)
- `https://wails.io/docs/reference/runtime/events` — `EventsEmit` / `EventsOn` reference for Wails v2
- `https://developers.google.com/gmail/api/reference/rest/v1/users.drafts/create` — Gmail Drafts API (already exercised by `internal/mapi/gmail.go`)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`src/app/watcher_bridge.go`** — The 1-slot `pending` channel + dispatcher goroutine is the exact pattern automode needs. Extend it OR add a second goroutine that listens to the same `pending` signal + queries `MakeAuthenticatedGmailCall` + `watcher.MarkProcessed`. Planner picks the cleanest layout — one dispatcher with two fan-outs vs two dispatchers reading from one signal channel. WR-03 lives here (line 93) and must be fixed as part of D-18.
- **`src/app/auth.go` — `MakeAuthenticatedGmailCall(ctx, fn)`** — already the right abstraction for automode. Handles refresh-if-near-expiry + 401 retry-once + `invalid_grant` classification. Phase 9 automode wraps `fn = func(token string) error { gc := mapi.NewGmailClient(token); _, err := gc.CreateDraft(msg); return err }`.
- **`src/app/tray.go` — `SetTrayError` / `SetTrayIdle`** — Phase 9 adds `SetTrayHasQueue(count int)` that swaps to `tray-has-queue.ico` and updates tooltip using the D-17 format. The tooltip-update logic should be consolidated into a single helper that takes `{mode, pausedBool, signedInBool, errorMsgStr, count}` and emits the right string.
- **Phase 8 `ReAuthBanner.svelte`** — reused for automode `invalid_grant` surface (D-10); no new component needed.
- **`internal/mapi/watcher.go` — `Snapshot()` / `MarkProcessed(id)` / `Delete(id)`** — Phase 9 wraps via new `App.CreateDraftForID(id)` and `App.DismissEmail(id)` bindings. `MarkProcessed` already deletes the JSON after draft (privacy-first).

### Established Patterns
- `fyne.io/systray` **must run on a `LockOSThread`ed goroutine** (Phase 7 Plan 03 `e8b95da` fix) — any new tray menu items (Pause, etc.) keep that invariant. Don't touch `systray.*` from other goroutines.
- Privacy-first logging: never log subject, body, or recipient addresses. Log counts + error categories only (Phase 7/8 convention, reinforced by QUAL-03).
- `sync.RWMutex` + `sync.Once` + `chan struct{}` done-signal for lifecycle; `atomic.Bool` for cross-goroutine flags (see `intentionalQuit` pattern in `app.go`).
- Error wrapping with `%w`; lowercase error strings.
- Wails `EventsEmit` must NOT fire from watcher hot paths (PITFALLS §5). Go through the 1-slot `pending` channel.
- Build-tag split for fatal startup guards (Phase 8 D-10 pattern) — if Phase 9 adds any fatal check, remember the `//go:build !bindings` split so `wailsbindings.exe` can introspect without triggering `os.Exit`.
- Test pattern for HTTP-mocked auth: `httptest.Server` + endpoint override variables (Phase 8.1 D-12). Apply to any new automode failure-path tests.
- Svelte 5 runes: `$state`, `$props()` destructuring, `$derived` — reuse existing component shape; Vitest + `@testing-library/svelte` + `svelteTesting()` plugin (Phase 8.1 D-09/D-10) are already wired.

### Integration Points — New App Struct Bindings
- **`App.CreateDraftForID(id string) error`** — called from row `Create draft` button. Invokes `MakeAuthenticatedGmailCall` → `GmailClient.CreateDraft` → `watcher.MarkProcessed(id)`. Emits `auto-draft-result` (or `draft-created`) event on success.
- **`App.DismissEmail(id string) error`** — called from row `Dismiss` button. Invokes `watcher.Delete(id)` (no Gmail API call). Does not require auth — can work when signed out.
- **`App.GetSettings() AppSettings`** — reads `%APPDATA%\go-mapi\settings.json`. Returns defaults if file missing.
- **`App.SaveSettings(s AppSettings) error`** — atomic write (tmp + rename). Called when user toggles mode or when code sets updatedFields.
- **`App.PauseWatching()` / `App.ResumeWatching()`** — session-only pause state. Bindings TBD (planner picks whether frontend needs to read paused state directly or only via tooltip).
- **New event: `auto-draft-result`** (payload `{emailId: string, success: bool, error?: string, errorCategory?: "signed-out"|"network"|"gmail"}`) — drives row badge + error toast. Planner decides whether this fires for success as well (D-04 already implies success feedback works via the existing `queue-update` + window-visibility check).

### Potential Landmines
- **WR-03 fix interaction.** The 1-slot pending channel is the core coalesce primitive; any automode fan-out must not break the coalesce guarantee (or must update the test assertion + docs accordingly). Planner sequences WR-03 fix BEFORE automode work so subsequent changes don't drift the assertion.
- **RDS multi-session isolation.** Toast activation libraries may register COM classes at machine scope — that breaks RDS. Researcher must validate chosen library survives multi-session. Same caveat for AUMID: HKCU (per-user) is RDS-safe; HKLM (per-machine) is not.
- **settings.json write races.** If automode writes to settings.json from a goroutine (e.g. timestamp-last-run) AND the UI writes mode changes, atomic-write + mutex is non-optional. Keep writes window-driven where possible; avoid background writes to settings.
- **Auto-draft vs sign-out transition.** If user signs out WHILE automode is draining a burst, the goroutine may be mid-call when `invalid_grant` fires. `MakeAuthenticatedGmailCall` already handles this — but the test surface must cover the race.
- **Toast removal race.** `MarkProcessed(id)` removes the JSON file. `History.Remove(tag, group)` removes the toast. If the user clicks the toast action before the Go code reaches `Remove`, we may process twice. Idempotency on `MarkProcessed` already guards; planner verifies for toast activation path too.
- **`tray-has-queue.ico` missing at build time.** Must land in `src/app/assets/tray/` + be embedded via `//go:embed` exactly like the existing two icons. Build will fail loudly if missing — fine, but the asset creation is a real task, not a trivial add.

</code_context>

<specifics>
## Specific Ideas

- **Mode toggle visual anchor:** Segmented control is the suggested default. Lives inline within the existing `SignedInHeader.svelte` layout. The control is only rendered when `auth.authenticated` is true — no need to show mode when signed out.
- **AUMID string:** `com.marcfargas.gomapi` for prod, `com.marcfargas.gomapi.dev` for dev. Reverse-DNS convention; matches Windows guidance.
- **Dev helper script path:** `scripts/register-dev-aumid.ps1`. Should be idempotent — running twice is a no-op. Logs the registered AUMID + shortcut path on completion.
- **Error toast copy (seed suggestions, UI-spec refines):**
  - `Sign-in expired — emails queued for manual review` (on first invalid_grant during automode)
  - `Draft failed — Sign-in expired` (per-email in automode after invalid_grant)
  - `Draft failed — Network error` (transient HTTP failure)
  - `Draft failed — Gmail error` (4xx/5xx from Gmail that isn't 401)
- **Draft-success toast copy (when window hidden):** `Draft created: <subject>` — optional `Open in Gmail` button if Gmail URL is reliably constructable (planner decides; punt-to-no-action is acceptable).
- **Tooltip examples** (D-17): `go-mapi — Auto-draft — 3 pending`, `go-mapi — Paused — 2 pending`, `go-mapi — Signed out — 1 pending`.
- **WR-03 sequencing:** Planner puts the test-hygiene plan (D-18) as Plan 01 or very early so subsequent feature plans run against green CI.
- **Privacy baseline (QUAL-03):** Toast content is sender + subject + attachment count — never body. Logs record counts + error categories — never email content. Reinforced in every new code path.
- **RDS primacy:** Researcher's toast + AUMID choices must explicitly call out RDS/RDP validation results. Default assumption: HKCU (per-user) registration path is RDS-safe; HKLM is not.

</specifics>

<deferred>
## Deferred Ideas

- **Bulk row actions (select multiple + batch draft / dismiss)** — PROJECT.md Out of Scope. Candidate for a v4+ UX phase if usage demand surfaces.
- **Row expand-to-show-detail (recipients, attachment filenames, no body preview)** — explicitly out of Phase 9 per D-03. Revisit in a later polish phase if users ask for it.
- **Retroactive auto-draft of backlog after re-auth** — explicitly rejected per D-10. Research + user both against; duplicate-draft risk. Never.
- **Pause with auto-expiry (Slack-style "Pause for 1 hour")** — considered and rejected for Phase 9 (added complexity; session-only suffices). Possible future enhancement.
- **Mode toggle duplicated in tray menu** — rejected per D-12 (surface area tradeoff). Revisit if telemetry ever shows users can't find the toggle.
- **Runtime-composed tray badge with numeric count overlay** — rejected per D-16 (runtime image work + DPI-scaling edge cases). Static variant + tooltip count suffices.
- **Distinct tray icon variants for paused / signed-out** — not shipped in Phase 9; tooltip carries the state. Revisit if UI-spec argues for it.
- **`Open in Gmail` deep link on draft-success toast** — Claude's Discretion; may or may not ship in Phase 9. Low-complexity, low-stakes addition.
- **Auto-send mode + undo-send window** — Out of Scope for v3.0 per PROJECT.md (irreversibility risk). Preserved as future capability.
- **Per-email mode override** — Out of Scope per PROJECT.md (confusing UX for non-technical users). v4+ candidate.
- **Audit log of automode actions for enterprise admins** — ENT-03 in REQUIREMENTS.md future-requirements; not v3.0.
- **Telemetry for automode failure rates** — QUAL-03 forbids telemetry; deferred indefinitely.
- **Windows Focus Session suppression (`SuppressPopup=true` during Focus)** — FEATURES.md §2 differentiator (LOW); nice-to-have if researcher finds it trivial, otherwise defer.
- **Toast inline images (sender avatar, attachment thumbnail)** — privacy-and-complexity concerns; out of Phase 9.
- **`go-mapi` settings UI panel** — for v3.0, the mode toggle in the header is the only setting. If update-opt-out (Phase 11 REL-05) and dev-mode flags accumulate, a dedicated Settings view becomes worthwhile in a later phase.

</deferred>

---

*Phase: 09-queue-automode-toasts*
*Context gathered: 2026-04-19*
