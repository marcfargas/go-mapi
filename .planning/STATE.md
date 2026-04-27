---
gsd_state_version: 1.0
milestone: v3.0
milestone_name: Wails Pivot
status: executing
stopped_at: Phase 11.1-04 complete — silent updater download+verify+swap pipeline landed; ready for Plan 11.1-05 (Scheduled Task XML + NSIS wiring)
last_updated: "2026-04-27T20:23:32.442Z"
last_activity: 2026-04-27
progress:
  total_phases: 7
  completed_phases: 5
  total_plans: 45
  completed_plans: 42
  percent: 93
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-12)

**Core value:** A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.
**Current focus:** Phase 11.1 — installer-hardening-enterprise-deploy-silent-auto-update

## Current Position

Milestone: v3.0 Wails Pivot
Phase: 11.1 (installer-hardening-enterprise-deploy-silent-auto-update) — EXECUTING
Plan: 5 of 6 (next: 11.1-05 Scheduled Task XML + NSIS /AUTOUPDATE wiring)
Status: Ready to execute
Last activity: 2026-04-27 — Phase 11.1-04 (silent updater download/verify/swap) landed

Progress: [█████████░] 93%

## Performance Metrics

**Velocity (v2.1.0):**

- Total plans completed: 3
- Phase 6 shipped 2026-04-12

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions carried into v3.0:

- v3.0: Replace browser extension with standalone Wails (Go + WebView2) desktop app — see seed note
- v3.0: Clean-break migration — users uninstall v2.x, install v3.0 fresh
- v3.0: Retire Chrome/Edge extension from stores on v3.0 ship
- v3.0: Per-instance RAM target ≤ 80 MB idle (revised from 10-30 MB per research; 30 MB remains stretch goal)
- v3.0: Two-mode toggle — Manual / Auto-draft (Auto-send deferred; out of scope for v3.0)
- v3.0: Stack locked — Wails v2.12.0, fyne.io/systray v1.12.0 (RunWithExternalLoop), Go 1.23, Svelte 5
- v3.0: OAuth via golang.org/x/oauth2 PKCE loopback; tokens in zalando/go-keyring (Windows Credential Manager)
- v3.0: Autoupdate notify-only via creativeprojects/go-selfupdate (no in-process binary replacement)
- v3.0: NSIS installer (not Inno Setup) — AppUserModelID + Start Menu shortcut + WebView2 bootstrapper
- Preserved: MAPI DLL, filesystem IPC, delete-on-process privacy model
- [Phase 08]: D-08/D-09/D-10 realised: package-level var oauthClientID/_Secret with ldflags -X targets, env-var fallback for wails dev, fail-fast guard before wails.Run
- [Phase 08]: Dev dotfiles at repo root: .env.local / .env.local.example live at C:\dev\go-mapi root, not under src/app/ (visibility preference)
- [Phase 08]: Build-tag split pattern required for wails build compatibility: any fatal startup guard in main.go must be extracted to a !bindings-tagged file so wailsbindings.exe can introspect types without triggering os.Exit
- [Phase 08]: D-11/D-12 realised: zalando/go-keyring v0.2.8 wired for Windows Credential Manager; keyring.ErrNotFound on Get/Delete is signed-out state (not error); service=go-mapi user=oauth-tokens
- [Phase 8.1]: KeyringStore interface seam in src/app/auth.go for cross-platform unit tests (fakeKeyringStore for non-Windows; realKeyringStore wraps zalando/go-keyring on Windows)
- [Phase 8.1]: Root npm workspaces empirically confirmed as ["src/app", "src/app/frontend"] — npm workspaces is flat, frontend sub-workspace cannot be auto-discovered from src/app/package.json
- [Phase 8.1]: Vitest + @testing-library/svelte 5 requires svelteTesting() Vite plugin (not documented in PATTERNS but mandated by the library's README for runes mount() to pick the browser entry)
- [Phase 8.1]: CI convention — build-wails-app job on windows-latest, CGO_ENABLED=1, Go 1.25, per-PR -race + coverage for internal/mapi and src/app, svelte-check + Vitest blocking, wails build sanity
- [Phase 8.1]: Test hygiene debts carried forward (recorded in 08.1-REVIEW.md and surfaced on first CI run 2026-04-19): WR-01 TestAuthCodeURLHasPKCE t.Parallel + package-var mutation pattern; WR-02 bootstrap-auth tests leak a goroutine to the real Google userinfo endpoint; WR-03 TestDispatcherCoalesces (src/app/watcher_bridge_test.go:93, originated in Phase 7 commit 36ca9e8) flakes under -race on windows/amd64 — asserts count==1 but legal outcomes under the 1-slot pending channel design are count ∈ {1,2} when the dispatcher drains the first value before OnQueueChanged burst completes. All three to fix in Phase 9 test-hygiene pass.
- [Phase 8.1]: CI pwsh arg-parsing gotcha: default shell on windows-latest is pwsh, which splits `-coverprofile=file.ext` at the `.` and hands `.ext` to go test as a package arg. Fix: `shell: bash` on `go test -race -coverprofile=…` steps (commit 9ef064d). Alternative: wrap value in single quotes.
- [Phase 8.1]: Develop branch CI remains RED after phase closure until Phase 9 fixes WR-03 — user-accepted tradeoff; scope discipline kept test-hygiene work out of Phase 8.1's files_modified.
- [Phase 9]: WinRT `IToastNotificationFactory.CreateToastNotification` is an instance method — must pass the factory `*IUnknown` as `this`, not `0`. Passing `0` compiles but nil-derefs on `.Release()`. Mirror `showToast`/`setTagGroup` pattern. (CR-01, commit `5f7f46a`)
- [Phase 9]: AUMID must be ldflags-injectable — use `var aumidOverride string` + `activeAUMID()` fallback pattern (mirrors `oauthClientID`/`oauthClientSecret` from Phase 8). Do NOT ship a release build with `com.marcfargas.gomapi.dev` hardcoded — it would permanently persist under that identity in every user's Action Center. (WR-01, commit `269fc25`; Phase 10 populates `-X github.com/marcfargas/go-mapi/app.aumidOverride=com.marcfargas.gomapi`)
- [Phase 9]: `watcher.Start()` must complete synchronously (i.e. `processExistingFiles` done) BEFORE seeding `knownIds` via `Snapshot()` — otherwise every pre-existing JSON fires a spurious arrival toast. The arrival-detection pattern is: snapshot-after-start seeds the baseline, then `SetAfterDispatch` detects genuinely-new IDs by set diff. (WR-02, commit `e7daf14`)
- [Phase 9]: Svelte 5 reactive `Map`/`Set` mutations via `.set()`/`.delete()` do NOT trigger re-renders from callbacks registered in `onMount` — must reassign (`autoDraftErrors = new Map(autoDraftErrors)`). Signal-driven reactivity needs a new reference, not in-place mutation, when the write happens outside the synchronous component scope.
- [Phase 9]: Toast shim uses `QueryInterface` (returns `(*IUnknown, error)`), NOT `MustQueryInterface` (panics on failure). In Go test runners outside a real WinRT host, `MustQueryInterface` panics cascade through the test runner even with recover. Propagate errors via Go's normal error path.
- [Phase 9]: Manual QA gate pattern for Windows shell features (tray, toast, live UI): DEFERRED in favor of Windows Sandbox + FlaUI automation todo (`.planning/todos/pending/2026-04-19-automate-tray-visual-qa-windows-sandbox.md`). Surfaces in `09-HUMAN-UAT.md`. All 3 deferred checks are tracked for closure by either a manual pass or the automation harness.
- [Phase 10]: All six Phase 10 plans have completion summaries on 2026-04-20. Remaining work is human/CI verification debt recorded in `10-VERIFICATION.md` and `10-HUMAN-UAT.md`; per user direction, that debt is accepted for progression and does not block Phase 11.
- Phase 11.1-04: errChecksumFailed sentinel + filename-only abort log keeps go-selfupdate's hex-digest validator errors out of update.log (Pitfall 6 / T-11.1.04-06)
- Phase 11.1-04: Verify-BEFORE-write (not just verify-BEFORE-swap) — downloadAndVerify runs ChecksumValidator on in-memory bytes BEFORE os.WriteFile so an unverified asset never hits disk; strengthens T-11.1.04-02 mitigation

### Roadmap Evolution

- Phase 8.1 inserted after Phase 8 (2026-04-18): Post-pivot cleanup and test coverage review (URGENT) — purge v2.x native-host + browser-extension leftovers and shore up Wails codebase test coverage before Phase 9 feature work resumes
- Phase 8.1 completed 2026-04-19 (7/7 must-haves; 9 plans / 7 waves; 2 warnings routed as non-blocking test-hygiene follow-ups for Phase 9)
- Phase 9 planned 2026-04-19 (9 plans / 6 waves; plan-checker PASSED zero blockers). 09-01 closes WR-01/02/03 to green-up develop CI BEFORE 09-03 watcher_bridge fan-out lands. Toast plan 09-06 carries the NOTIF-05 wintoast shim (~150 LOC, go-ole + x/sys/windows) as the highest-risk item; flagged `autonomous: false` with manual-QA checkpoint.
- Phase 9 completed 2026-04-19 (5/5 must-haves; 9 plans / 6 waves). Code-review found 1 critical + 5 warnings — all closed in the REVIEW-FIX pass. Verification status `human_needed` — 3 UAT items (tray visual, toast E2E, full user-flow) deferred to the Windows Sandbox + FlaUI automation todo. Develop CI green again after 09-01 landed WR-01/02/03 fixes.
- Phase 10 completed 2026-04-20 from an implementation standpoint (10-01 through 10-06 all landed). Verification status remains `human_needed`, but the remaining manual/CI checks are accepted as non-blocking for progression into Phase 11.
- Phase 11.1 inserted after Phase 11 (2026-04-24): Installer hardening + enterprise deploy + silent auto-update (URGENT — in-flight). Scope: All Users install made mandatory (single-user dropped — MAPI is inherently machine-wide); T2 NSIS `SetShellVarContext all` fix; T4 32-bit DLL reinstall-overwrite fix; T7 machine-wide `%PROGRAMDATA%\go-mapi\go-mapi.machine.yaml` config surface; T8 ship `*.yaml.example` files; T6 silent auto-selfupdate via Scheduled Task with tri-state install option (None / Notify / Silent, Notify default); CI + README refresh for enterprise story. Phase 11's remaining 11-04 Task 2+3 (Chrome/Edge delisting + GA tag push) explicitly moved to AFTER v3.0 ships and `go-mapi-www` is live — non-blocking post-GA housekeeping.

### Pending Todos

- AUTH-06: Google OAuth verification submitted 2026-04-17 (GCP client, consent screen, scope justifications done; 4-8 week review window running)
- AUTH-06b: Record and upload YouTube demo video for OAuth verification — blocked until Plan 08-05 ships end-to-end sign-in + draft flow. See `.planning/todos/pending/2026-04-17-oauth-verification-youtube-demo-video.md`

### Blockers/Concerns

- Google OAuth verification (AUTH-06) is a 4-8 week external dependency — late submission blocks launch
- Phase 7 measurement-methodology follow-up: iter 2/3 single-instance mutex race in `measure-ram.ps1` (see 07-VERIFICATION.md §Methodology Caveats). Not a blocker; only matters if RAM gate needs re-running.

### Resolved

- ~~RAM profile under RDS conditions is unvalidated~~ — RESOLVED 2026-04-14: Phase 7 Plan 04 measured 43.24 MB mean per session on 5 concurrent sessions (n=4 clean), well under 80 MB gate; verdict PASS. Full report: 07-VERIFICATION.md.

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 260423-msq | Relocate DLL queue to %LOCALAPPDATA%\go-mapi\queue\ + diagnostic scripts | 2026-04-23 | 395cb7e | [260423-msq-relocate-dll-queue-to-localappdata-and-a](./quick/260423-msq-relocate-dll-queue-to-localappdata-and-a/) |
| 260423-ntu | 32-bit DLL support + uninstaller running-process guard + diagnostic script null-ref fixes | 2026-04-23 | 3744b00 | [260423-ntu-32-bit-dll-support-uninstaller-process-c](./quick/260423-ntu-32-bit-dll-support-uninstaller-process-c/) |
| 260423-olq | Wails build wrapper reads .env.local and injects OAuth via ldflags | 2026-04-23 | adc8c16 | [260423-olq-wails-build-wrapper-reads-env-local-and-](./quick/260423-olq-wails-build-wrapper-reads-env-local-and-/) |
| 260423-qpx | Address fallback for legacy Simple MAPI apps + fix dev-build update compare | 2026-04-23 | 5876088 | [260423-qpx-address-fallback-for-legacy-mapi-apps-fi](./quick/260423-qpx-address-fallback-for-legacy-mapi-apps-fi/) |
| 260423-tk6 | DLL copies attachments into queue-owned dir + surface draft-failure reason in UI | 2026-04-23 | 30b35c6 | [260423-tk6-dll-copies-attachments-to-queue-surface-](./quick/260423-tk6-dll-copies-attachments-to-queue-surface-/) |
| Phase 11.1 P11.1-04 | 905s | 2 tasks | 2 files |

## Session Continuity

Last session: 2026-04-27T20:23:32.431Z
Stopped at: Phase 11.1-04 complete — silent updater download+verify+swap pipeline landed; ready for Plan 11.1-05 (Scheduled Task XML + NSIS wiring)
Resume: finish go-mapi-www (c:/dev/go-mapi-www), update Chrome Web Store + Edge Add-ons listings with deprecation copy, paste proof into `.planning/phases/11-autoupdate-release/11-RELEASE-EVIDENCE.md`, then run `/gsd-execute-phase 11` and reply `approved` at the checkpoint
