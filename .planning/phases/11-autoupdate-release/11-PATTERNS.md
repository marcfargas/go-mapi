# Phase 11: Autoupdate + Release - Pattern Notes

**Mapped:** 2026-04-21
**Purpose:** Planner-facing implementation notes for update checks, persisted settings, tray/menu actions, Wails event/state plumbing, release workflow docs, and smoke-test automation handoff.

## Scope Shape

Phase 11 naturally decomposes into five ownership areas that already exist in the codebase:

| Area | Primary files | Data flow | Existing owner |
|---|---|---|---|
| Persisted update preferences | `src/app/settings.go`, `src/app/app.go`, `src/app/frontend/src/lib/settings.ts` | request-response + file I/O | Go backend settings model |
| Update check execution/state | new `src/app/*` backend file(s), `src/app/app.go` | request-response + event-driven | Go backend / Wails bindings |
| Tray/menu affordances | `src/app/tray.go`, `src/app/tray_test.go` | event-driven | tray goroutine |
| In-window banner/panel | `src/app/frontend/src/App.svelte`, likely new small Svelte component | request-response + event-driven | root frontend shell |
| Release/docs/smoke handoff | `.github/workflows/installer-release.yml`, `.github/release-template.md`, `README.md`, separate smoke artifact/docs | batch + docs | workflow/docs layer |

## Reusable Seams

### 1. Persisted settings stay flat, per-user, and single-writer

Use [`src/app/settings.go`](C:/dev/go-mapi/src/app/settings.go:14) as the canonical persistence pattern.

- [`AppSettings`](C:/dev/go-mapi/src/app/settings.go:20) is intentionally flat. The comment at lines 14-19 explicitly says future phases should add flat fields and not introduce a second config file.
- [`loadSettings`](C:/dev/go-mapi/src/app/settings.go:32) is tolerant: missing/corrupt/unknown values fall back to defaults instead of surfacing UI errors.
- [`saveSettings`](C:/dev/go-mapi/src/app/settings.go:57) is atomic and explicitly restricted to UI-thread/Wails-binding writes.

Planner implication:

- Add update-related fields to `AppSettings`; do not create `updates.json`, localStorage state, or a second persistence path.
- Favor primitive flat fields such as `UpdateChecksEnabled` and a serialized last-check timestamp/string. Keep validation/coercion in Go.
- Any automatic 24h cadence logic must read persisted state, but must not write settings from background goroutines. Route writes through an App binding / UI-owned method or a guarded backend method that preserves the single-writer invariant.

### 2. `app.go` is the backend state hub; bindings are thin and future-proofed

Use [`src/app/app.go`](C:/dev/go-mapi/src/app/app.go:16) as the ownership model.

- Startup already hydrates auth, watcher, settings, automode, and tray in one place at [`startup`](C:/dev/go-mapi/src/app/app.go:82).
- Settings access is centralized through [`GetSettings`](C:/dev/go-mapi/src/app/app.go:523), [`SaveSettings`](C:/dev/go-mapi/src/app/app.go:535), and convenience wrappers like [`GetMode`/`SetMode`](C:/dev/go-mapi/src/app/app.go:542).
- State changes that the frontend needs are pushed as Wails events, e.g. [`pause-changed`](C:/dev/go-mapi/src/app/app.go:294) and [`auto-draft-result`](C:/dev/go-mapi/src/app/app.go:426).

Planner implication:

- Put update-check orchestration under `src/app/`, but keep `App` as the public Wails boundary.
- Prefer one aggregate binding that returns update state over many narrow bindings. The existing comment on [`GetSettings`](C:/dev/go-mapi/src/app/app.go:523) already points toward “future fields land in AppSettings, not parallel bindings.”
- Manual “Check for updates now” should be a Wails/App method. Background startup/cadence logic should update in-memory App state and emit a dedicated update event.
- Follow the existing event contract style: compact payloads, no secrets, frontend subscribes via `EventsOn`.

### 3. Tray code owns menu lifecycle; app goroutines only mutate state and signal

Use [`src/app/tray.go`](C:/dev/go-mapi/src/app/tray.go:21) and [`src/app/tray_test.go`](C:/dev/go-mapi/src/app/tray_test.go:9) as the tray pattern.

- The core rule is in the comment at [`trayState` / `computeTrayVisual`](C:/dev/go-mapi/src/app/tray.go:21): callers mutate state and signal; they do not call `systray.*` directly.
- The tray is thread-affine. [`startTray`](C:/dev/go-mapi/src/app/tray.go:64) locks an OS thread and [`refreshTrayVisual`](C:/dev/go-mapi/src/app/tray.go:139) must run only there.
- Menu items are created and owned inside [`onTrayReady`](C:/dev/go-mapi/src/app/tray.go:85). Current examples are `Show`, `Pause watching`, and `Quit`.
- Coalesced refresh signaling already exists via [`signalTrayRefresh`](C:/dev/go-mapi/src/app/app.go:331) and is tested in [`TestSignalTrayRefresh_Coalesces`](C:/dev/go-mapi/src/app/tray_test.go:54).

Planner implication:

- Add update toggle and manual-check menu items in `onTrayReady`, not elsewhere.
- If tray text needs “Last checked” or current version context, compute it from App state and update it on the tray goroutine only.
- Reuse the existing pattern of changing app state first, then flipping any menu title/checked state as view-only reflection.
- Add pure helper coverage for any new tray-label formatting before relying on live-shell QA.

### 4. Frontend root shell already hydrates initial state in parallel and listens for backend pushes

Use [`src/app/frontend/src/App.svelte`](C:/dev/go-mapi/src/app/frontend/src/App.svelte:50) and [`src/app/frontend/src/lib/settings.ts`](C:/dev/go-mapi/src/app/frontend/src/lib/settings.ts:14).

- `App.svelte` fetches initial state with one `Promise.all` on mount at lines 50-57.
- It stores shell-level state in the root component and cleans up all event subscriptions through a shared `unsubs` array at lines 47-48 and 136-138.
- Existing event-driven UI state follows a compact pattern: Go emits, `lib/*.ts` exposes typed wrappers, and `App.svelte` updates local `$state`.
- [`settings.ts`](C:/dev/go-mapi/src/app/frontend/src/lib/settings.ts:36) is intentionally thin: bindings + typed subscriptions, no business logic.
- Existing frontend tests lock that contract in [`settings.test.ts`](C:/dev/go-mapi/src/app/frontend/src/lib/settings.test.ts:49) and [`App.test.ts`](C:/dev/go-mapi/src/app/frontend/src/App.test.ts:85).

Planner implication:

- Put any new update bindings/subscriptions in `src/app/frontend/src/lib/settings.ts` or a dedicated `lib/updates.ts` if separation materially improves clarity.
- Mount the persistent update banner/panel in `App.svelte` or a child component directly under it. Do not add a dedicated settings page for one toggle.
- Follow the current root-shell pattern:
  - fetch initial update state in the mount `Promise.all`
  - subscribe to a compact event such as `update-state-changed`
  - keep banner dismissal/UI-only state in frontend state unless requirements explicitly say dismissal must persist
- Extend existing App/lib tests rather than inventing a different frontend test style.

### 5. Release workflow is additive; `wails.json` remains version authority

Use [`src/app/wails.json`](C:/dev/go-mapi/src/app/wails.json:13) and [`installer-release.yml`](C:/dev/go-mapi/.github/workflows/installer-release.yml:62).

- `info.productVersion` is the release authority, and the workflow already enforces tag/version match at lines 62-81.
- The release workflow already publishes `go-mapi-setup.exe` and uses `.github/release-template.md` as the release body at lines 175-182.
- The stable URL behavior is implicit in attaching the same asset name to GitHub Releases; Phase 11 should preserve that, not redesign it.

Planner implication:

- Do not add a second version source.
- Workflow changes should be additive and narrowly scoped to Phase 11 artifacts or guidance, not a release-pipeline rewrite.
- If autoupdate logic needs the current version at runtime, read the same `Version` / `wails.json` authority chain already used for release builds.

### 6. Release notes and README own the cutover language

Use [`release-template.md`](C:/dev/go-mapi/.github/release-template.md:1) and [`README.md`](C:/dev/go-mapi/README.md:54).

- The release template is already v3-oriented and explicitly tells users to uninstall v2 first at lines 11-13.
- `README.md` still presents some Phase 10 transitional language, including “Phase 11 planned” in the status table at lines 5-15 and “installer ships in Phase 10” at line 59.

Planner implication:

- Phase 11 docs work is not just copy polish; it is a state transition from “planned/in progress” to “shipped/v3-only.”
- Treat `.github/release-template.md` and `README.md` as a coordinated docs slice with shared cutover language.
- The store retirement proof/evidence likely belongs outside these files, but the planner should include a deliverable for recording that proof.

### 7. Existing CI smoke only covers installer round-trip; clean-machine full-flow needs a separate handoff artifact

Use [`installer-smoke.yml`](C:/dev/go-mapi/.github/workflows/installer-smoke.yml:33) and the sandbox automation todo at [`2026-04-19-automate-tray-visual-qa-windows-sandbox.md`](C:/dev/go-mapi/.planning/todos/pending/2026-04-19-automate-tray-visual-qa-windows-sandbox.md:24).

- The current smoke workflow explicitly avoids launching the app or embedding OAuth secrets at lines 33-40 and only runs installer/uninstaller Pester smoke at lines 109-116.
- The sandbox todo documents the current accepted pattern for shell/UI verification: separate Windows Sandbox + UI Automation harness, richer than unit tests, and not runnable on GitHub-hosted `windows-latest`.

Planner implication:

- Do not overload `.github/workflows/installer-smoke.yml` with live OAuth/Gmail/UI flow on hosted CI.
- Phase 11 should produce a handoff artifact for clean-machine validation: script bundle, checklist, evidence format, and where screenshots/video land.
- If automation is partial, the manual tail must be explicit and short. The planner should make that a first-class output, not a vague “manual verification later.”

## File Ownership Boundaries

### `src/app/settings.go`

- Owns persisted schema, defaults, normalization, atomic disk write.
- Should absorb new persisted update preference fields.
- Should not own network update-check logic.

### `src/app/app.go`

- Owns backend in-memory state, startup wiring, Wails bindings, and event emission.
- Best home for update-check API surface and state fan-out to tray/frontend.
- Should coordinate startup check cadence, not the tray or frontend directly.

### `src/app/tray.go`

- Owns menu items, tooltip/icon refresh, and tray-thread-safe rendering.
- Should only render update status/actions, not perform update network calls inline.

### `src/app/frontend/src/lib/settings.ts` or a sibling update module

- Owns typed frontend wrappers over Go bindings/events.
- Should stay thin and testable.

### `src/app/frontend/src/App.svelte`

- Owns root-shell state hydration and event subscriptions.
- Best integration point for persistent update banner and in-app update panel.

### `.github/workflows/installer-release.yml`

- Owns signed-release assembly and release upload.
- Should remain the source of truth for stable asset publication behavior.

### `.github/release-template.md` and `README.md`

- Own end-user release/cutover messaging.
- Should not accumulate legacy v2 maintenance docs.

### Smoke artifacts/docs

- Should live outside the release workflow file itself.
- Likely a separate script/docs bundle under `scripts/`, `tests/`, or `.planning/phases/11-autoupdate-release/` evidence docs, depending on how much automation lands.

## Expected Plan Decomposition

The current seams suggest the planner should break Phase 11 roughly like this:

1. Backend update model + persisted preferences
   - Extend `AppSettings`
   - Add validation/defaulting
   - Add App-level update state and manual/background check entry points
   - Add Go tests around persisted settings + cadence logic

2. Tray/menu integration
   - Add tray toggle and manual action
   - Reflect current version / last checked / enabled state without violating tray thread affinity
   - Add/extend pure tray tests for any new formatting logic

3. Frontend banner/panel plumbing
   - Add typed bindings/event wrappers
   - Hydrate initial update state on mount
   - Add persistent banner + in-app panel in root shell
   - Add/extend Vitest coverage in `App.test.ts` and wrapper tests

4. Release/docs cutover
   - Finalize README to v3-only shipped state
   - Strengthen release template cutover messaging
   - Document stable installer URL and manual update path consistently
   - Record browser-store retirement proof requirements

5. Clean-machine smoke handoff
   - Reuse installer smoke as the lower layer
   - Produce separate reproducible clean-machine flow harness/checklist/evidence bundle
   - Define screenshot/video/manual-tail expectations explicitly

## Risks That Should Be Explicit in PLAN.md

- **Tray thread-affinity regression:** any direct `systray.*` call from a non-tray goroutine will recreate the class of bug fixed in `tray.go`.
- **Settings write races:** background cadence code must not call `saveSettings` opportunistically from worker goroutines if the single-writer invariant still applies.
- **Noisy failure UX:** Phase context says transient GitHub/update-check failures are silent. Planner should require logging-only failure handling and tests for “no banner/no tray error on fetch failure.”
- **Version-source drift:** update logic and release docs must use the existing version authority, not hard-coded strings.
- **Over-coupling UI to tray:** update state should live in backend/App state once and fan out to tray + frontend, not be duplicated independently in each surface.
- **Hosted CI limitations:** GitHub-hosted Windows runners cannot provide the full clean-machine shell/UI/OAuth path expected by Phase 11. The planner should separate CI smoke from sandbox/manual evidence work.
- **Secrets/artifact leakage:** current smoke workflow intentionally avoids embedding OAuth secrets in public artifacts. Any new smoke or release-adjacent automation must preserve that boundary.
- **Scope creep into true self-update:** planner should guard against installer launch helpers, in-process replacement, or “quit and install” behavior.
- **Date/cadence ambiguity:** “24h cadence” needs a persisted last-check timestamp and clear comparison semantics; otherwise startup checks may spam or never run.
- **Dismissal semantics ambiguity:** the persistent banner can be dismissible, but the planner should state whether dismissal is session-only or version-scoped to avoid accidental permanent suppression.

## Strongest Analogs To Copy

- Persisted flat settings + atomic save: [`src/app/settings.go`](C:/dev/go-mapi/src/app/settings.go:14)
- App-level binding/state/event fan-out: [`src/app/app.go`](C:/dev/go-mapi/src/app/app.go:523)
- Tray signal/render split: [`src/app/tray.go`](C:/dev/go-mapi/src/app/tray.go:21)
- Coalesced event bridge pattern: [`src/app/watcher_bridge.go`](C:/dev/go-mapi/src/app/watcher_bridge.go:12)
- Thin frontend binding wrappers: [`src/app/frontend/src/lib/settings.ts`](C:/dev/go-mapi/src/app/frontend/src/lib/settings.ts:14)
- Root-shell mount + subscription pattern: [`src/app/frontend/src/App.svelte`](C:/dev/go-mapi/src/app/frontend/src/App.svelte:50)
- Binding tests with temp `%APPDATA%`: [`src/app/app_bindings_test.go`](C:/dev/go-mapi/src/app/app_bindings_test.go:25)
- Frontend event wiring tests: [`src/app/frontend/src/App.test.ts`](C:/dev/go-mapi/src/app/frontend/src/App.test.ts:85)
- Stable release asset publication: [`installer-release.yml`](C:/dev/go-mapi/.github/workflows/installer-release.yml:175)
- Existing lower-layer smoke workflow: [`installer-smoke.yml`](C:/dev/go-mapi/.github/workflows/installer-smoke.yml:27)

## Planner Bottom Line

Phase 11 does not need a new architecture. The codebase already has the right seams:

- one persisted settings model
- one App-owned backend state hub
- one tray render thread with signal-based refresh
- one root frontend shell with typed Wails event plumbing
- one additive release workflow
- one lower-layer installer smoke gate plus a known gap for clean-machine UI automation

The planner should keep those seams intact and split work by owner boundary, not by surface-level feature list.
