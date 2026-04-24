# Roadmap: go-mapi

## Milestones

- ✅ **v2.0.0 Installer UX + Test-Suite Completeness** — Phases 1-5 (shipped 2026-04-12) — see `milestones/v2.0.0-ROADMAP.md`
- ✅ **v2.1.0 Release Pipeline (capped)** — Phase 6 only; Phases 7-9 dropped for v3.0 Wails pivot (shipped 2026-04-12) — see `milestones/v2.1.0-ROADMAP.md`
- 🚧 **v3.0 Wails Pivot** — Phases 7-11 (in progress) — standalone Wails desktop app replacing Chrome/Edge extension

## Phases

<details>
<summary>✅ v2.0.0 Installer UX + Test-Suite Completeness (Phases 1-5) — SHIPPED 2026-04-12</summary>

- [x] Phase 1: Foundation & SignPath Application (8/8 plans) — completed 2026-04-10
- [x] Phase 2: Extension Install UX (4/4 plans) — completed 2026-04-10
- [x] Phase 3: Inno Setup Installer + Signing + Distribution (4/4 plans) — completed 2026-04-10
- [x] Phase 4: Test-Suite Completeness + E2E (4/4 plans) — completed 2026-04-10
- [x] Phase 5: Release Cut (4/4 plans) — completed 2026-04-12

Full details: `milestones/v2.0.0-ROADMAP.md`

</details>

<details>
<summary>✅ v2.1.0 Release Pipeline (capped) (Phase 6) — SHIPPED 2026-04-12</summary>

- [x] Phase 6: Changesets Monorepo Scaffold (3/3 plans) — completed 2026-04-12
- ~~Phase 7: Extension Publishing Pipeline~~ — dropped (v3.0 Wails pivot)
- ~~Phase 8: Host Release Pipeline~~ — dropped (v3.0 Wails pivot)
- ~~Phase 9: Pipeline Integration and Legacy Retirement~~ — dropped (v3.0 Wails pivot)

Full details: `milestones/v2.1.0-ROADMAP.md`

</details>

### 🚧 v3.0 Wails Pivot (In Progress)

**Milestone Goal:** Replace the browser-extension + native-host split with a standalone Wails (Go + WebView2) desktop app. C++ MAPI interceptor and filesystem IPC stay unchanged; UI moves to system tray + native window, enabling automode, toast notifications, desktop OAuth, and autoupdate. Target RAM profile: ≤ 80 MB idle per instance (RDS constraint — measured in Phase 7).

- [x] **Phase 7: Wails Shell + RAM Gate** — Minimal tray app built and RAM measured (PASS: 43.24 MB mean per session vs 80 MB gate, 2026-04-14)
- [x] **Phase 8: OAuth + Credentials** — Desktop OAuth (PKCE loopback) with Windows Credential Manager storage shipped; human UAT approved 2026-04-18
- [x] **Phase 8.1: Post-pivot cleanup and test coverage review (INSERTED)** — Purge v2.x leftovers from the native-host + browser-extension era and shore up test coverage across the Wails codebase before Phase 9 feature work resumes
- [x] **Phase 9: Queue, Automode + Toasts** — Email queue UI, Manual/Auto-draft toggle, and Windows toast notifications
- [x] **Phase 10: Installer + Migration** — NSIS installer with AppUserModelID, WebView2 bootstrap, v2.x cleanup, uninstall, and release/smoke groundwork landed in 10-05 and 10-06
- [ ] **Phase 11: Autoupdate + Release** — Notify-only autoupdate, GitHub release pipeline, extension store retirement, smoke test
- [ ] **Phase 11.1: Installer hardening + enterprise deploy + silent auto-update (INSERTED)** — All Users install scope made mandatory, NSIS SetShellVarContext fixes, 32-bit DLL reinstall fix, machine-wide %PROGRAMDATA% config, yaml examples, silent auto-update install option, CI + README refresh for enterprise story

## Phase Details

### Phase 7: Wails Shell + RAM Gate
**Goal**: A minimal Wails desktop app runs on Windows with a system tray icon and passes the RAM measurement gate — confirming WebView2 is viable for the RDS constraint before any feature work begins
**Depends on**: Phase 6 (previous milestone complete)
**Requirements**: SHELL-01, SHELL-02, SHELL-03, SHELL-04, SHELL-05, SHELL-06, SHELL-07, QUAL-01, QUAL-02, QUAL-04
**Success Criteria** (what must be TRUE):
  1. User launches the app and a tray icon appears; left-click shows the main window, right-click shows a context menu with Quit; closing the window hides it to tray without quitting
  2. Launching a second instance raises the existing window rather than starting a duplicate process
  3. The existing `%TEMP%\go-mapi\` file watcher runs in the background whether the window is visible or hidden; queue changes are reflected in the UI without polling
  4. Per-instance RAM measured at ≤ 80 MB idle in tray-only mode on a Windows Server session (lazy WebView2 init); result documented before Phase 8 begins
  5. App exits cleanly on Windows logoff/shutdown and has no dependency on Chrome or Edge browsers being installed
**Plans**: 4 plans
- [x] 07-01-PLAN.md — Extract internal/mapi package + go.work + WatcherCallback (SHELL-06 foundation, QUAL-04)
- [x] 07-02-PLAN.md — Scaffold src/app Wails workspace + Svelte 5 frontend + tray icons (SHELL-01, SHELL-02, SHELL-03, SHELL-07)
- [x] 07-03-PLAN.md — Single-instance mutex + WM_QUERYENDSESSION + watcher fold-in (SHELL-04, SHELL-05, SHELL-06, QUAL-04)
- [x] 07-04-PLAN.md — RAM measurement gate on Azure WS2022 VM + three-outcome verdict (QUAL-01, QUAL-02) — **PASS 43.24 MB mean 2026-04-14**
**UI hint**: yes

### Phase 8: OAuth + Credentials
**Goal**: Users can authenticate with Google through a native desktop OAuth flow and stay signed in across restarts, with credentials stored securely in the Windows Credential Manager
**Depends on**: Phase 7
**Requirements**: AUTH-01, AUTH-02, AUTH-03, AUTH-04, AUTH-05, AUTH-06, AUTH-07, QUAL-03
**Success Criteria** (what must be TRUE):
  1. First-run user sees a sign-in prompt; clicking it opens the system browser (not an embedded webview) to the Google OAuth consent screen
  2. After consent, the app stores the refresh token in Windows Credential Manager (not on disk as plaintext); the user remains signed in after app restart
  3. When a Gmail API call returns 401, the access token refreshes transparently — the user is not interrupted mid-action
  4. If the refresh token is invalidated (`invalid_grant`), the user sees a clear re-sign-in prompt rather than a silent failure or retry loop
  5. The user can sign out from the main window; signing out clears the stored token from Credential Manager
**Plans**: 5 plans
- [x] 08-01-PLAN.md — GCP prerequisites gate + -ldflags credential injection (AUTH-06, QUAL-03)
- [x] 08-02-PLAN.md — AuthManager scaffold + keyring round-trip + Wails bindings (AUTH-03, QUAL-03)
- [x] 08-03-PLAN.md — SignIn flow: loopback + PKCE S256 + code exchange + userinfo (AUTH-01, AUTH-02, QUAL-03)
- [x] 08-04-PLAN.md — Token refresh + invalid_grant classification + SignOut + OnStartup wiring (AUTH-03, AUTH-04, AUTH-05, AUTH-07, QUAL-03)
- [x] 08-05-PLAN.md — Frontend: welcome screen + pre-auth modal + re-auth banner + signed-in header (AUTH-01, AUTH-02, AUTH-05, AUTH-07)

### Phase 8.1: Post-pivot cleanup and test coverage review (INSERTED) — ✓ COMPLETE 2026-04-19
**Goal**: The repository contains no residue of the v2.x native-host + browser-extension architecture, and every component of the Wails desktop app has test coverage appropriate to its risk — so Phase 9 feature work starts from a clean, coherent, well-tested baseline
**Depends on**: Phase 8
**Requirements**: QUAL-03 (carry-forward via D-05), QUAL-04 (closed by per-PR `-race` gate via D-07)
**Success Criteria** (what must be TRUE):
  1. `src/native-host/`, `src/extension/`, `src/installer/`, `tests/e2e/` do not exist; v2.x CI workflows (`e2e.yml`, `installer-release.yml`, `installer-smoke.yml`, `release.yml`) are removed
  2. `go.work` uses only `./internal/mapi` and `./src/app`; root `package.json` workspaces is `["src/app"]`; `.changeset/config.json` `$workspaces` is `["src/app"]`
  3. `internal/mapi/` retains the Gmail HTTP stub tests and MIME golden tests ported from `src/native-host/` before deletion (no silent loss of business-logic coverage)
  4. `src/app/frontend/` has a running Vitest + @testing-library/svelte harness with ≥ 7 test files covering `lib/auth.ts`, `lib/queue.ts` (incl. WR-03 regression), and the four existing components + an App smoke test
  5. `src/app/` Go coverage is extended: `KeyringStore` interface seam for cross-platform unit tests, Windows-only keyring integration test, eight gap-fill scenarios in `auth_test.go`, plus `app_test.go` / `paths_test.go` / `credentials_check_test.go`
  6. `.github/workflows/build.yml` has a single `build-wails-app` job that runs `go vet` + `go test -race -coverprofile` + `svelte-check` + Vitest + `wails build`; `build-interceptor` job preserved; `go-race-nightly.yml` updated to Go 1.25 + new module scope
  7. `CLAUDE.md` + `README.md` rewritten to describe the Wails v3.0 architecture with no v2.x references; `.planning/PROJECT.md` Key Decisions row for "risk-based gap filling" marked ✓ Good — extended to v3.0 Wails codebase in Phase 8.1
**Plans**: 9 plans
- [x] 08.1-01-PLAN.md — Port gmail_test.go + mime_golden_test.go + testdata/mime fixtures into internal/mapi (pre-deletion landmine fix)
- [x] 08.1-02-PLAN.md — Stand up Vitest + @testing-library/svelte + jsdom for src/app/frontend; 7 test files covering lib + components + App smoke (D-09, D-10)
- [x] 08.1-03-PLAN.md — Extend src/app Go coverage: KeyringStore interface, fake + real keyring tests, 8 auth gap-fills, app_test, paths_test, credentials_check refactor (D-11, D-12, D-05, QUAL-03)
- [x] 08.1-04-PLAN.md — Cleanup wave 1: drop src/native-host/, trim go.work + package.json + .changeset/config.json (D-02 wave 1, D-21)
- [x] 08.1-05-PLAN.md — Cleanup wave 2+3: drop src/extension/, src/installer/, ESLint config + devDeps, installer CI workflows, sharp devDep, generate-icons.js (D-02 waves 2-3, D-19)
- [x] 08.1-06-PLAN.md — Cleanup wave 4+5+6: drop tests/e2e/, tests/fixtures/, e2e.yml, release.yml, v2.x scripts + docs, TODO.txt, AGENTS.md / PLANNING_AGENT.md / CONTRIBUTING.md inspect-and-decide, drop @playwright/test (D-13, D-14, D-16, D-18)
- [x] 08.1-07-PLAN.md — Rewrite build.yml for Wails app + per-PR -race + coverage + svelte-check + Vitest (D-07, D-08, D-10, D-17, QUAL-04)
- [x] 08.1-08-PLAN.md — Finalize root package.json shape: description, repo URL, Wails-era aggregator scripts (D-22)
- [x] 08.1-09-PLAN.md — Rewrite CLAUDE.md + README.md for v3.0 Wails architecture; update PROJECT.md D-05 outcome (D-04, D-05)
**UI hint**: no

### Phase 9: Queue, Automode + Toasts — ✓ COMPLETE 2026-04-19
**Goal**: Users can view queued emails in the main window, act on them individually, set an automatic draft mode, and receive Windows toast notifications when new emails arrive
**Depends on**: Phase 8.1
**Requirements**: QUEUE-01, QUEUE-02, QUEUE-03, QUEUE-04, QUEUE-05, QUEUE-06, QUEUE-07, NOTIF-01, NOTIF-02, NOTIF-03, NOTIF-04, NOTIF-05
**Success Criteria** (what must be TRUE):
  1. The main window lists all pending emails showing sender, subject, attachment count, and timestamp; the list updates live when files appear in `%TEMP%\go-mapi\` without requiring a window refresh
  2. User can click "Create draft" on any email and a Gmail draft appears; user can click "Dismiss" to remove an email from the queue without drafting
  3. In Auto-draft mode, every new queued email becomes a Gmail draft automatically — including while the window is hidden; failed auto-drafts stay in the queue with a visible error state and a notification
  4. A Windows toast notification appears when a new email arrives in the queue, showing sender and subject only (no body text); toast action buttons allow "Create draft" or "Dismiss" without opening the main window
  5. The Auto-draft / Manual mode toggle persists across app restarts
**Plans**: 9 plans
- [x] 09-01-PLAN.md — Test hygiene pass (WR-01/02/03) — green-up develop CI before feature work
- [x] 09-02-PLAN.md — settings.json atomic write + appDataDir helper (D-13)
- [x] 09-03-PLAN.md — Automode goroutine + watcher_bridge fan-out + MarkProcessed idempotent + backlog-skip (D-09, D-10, D-14)
- [x] 09-04-PLAN.md — Wails bindings for queue actions + settings + pause (9 new App methods)
- [x] 09-05-PLAN.md — Tray has-queue icon + Pause menu + refreshTrayVisual (SHELL-02, SHELL-07, D-16, D-17)
- [x] 09-06-PLAN.md — Toast stack + WinRT shim (NOTIF-05) + COM activator + AUMID dev script (NOTIF-01..05)
- [x] 09-07-PLAN.md — Frontend: styles.css tokens + settings.ts + ReAuthBanner color alignment
- [x] 09-08-PLAN.md — Frontend: ModeToggle + AutoDraftErrorBadge components
- [x] 09-09-PLAN.md — Frontend: QueueRow + SignedInHeader extension + App.svelte rewire (QUEUE-01..07)
**UI hint**: yes

### Phase 10: Installer + Migration
**Goal**: A signed single-file installer sets up the Wails app for a new user (including WebView2 runtime and AppUserModelID), removes v2.x artifacts, and provides a clean uninstall path
**Depends on**: Phase 9
**Requirements**: INST-01, INST-02, INST-03, INST-04, INST-05, INST-06, INST-07
**Success Criteria** (what must be TRUE):
  1. A user with no prior go-mapi installation runs `go-mapi-setup.exe` and the app appears in the system tray within two minutes, including WebView2 runtime bootstrapping if it was absent
  2. On a machine with v2.x installed, the installer removes native messaging manifests, clears the old MAPI registry entries, and leaves no v2.x residue
  3. Toasts persist in the Windows Action Center (require AppUserModelID + Start Menu shortcut — both registered by installer)
  4. Running the uninstaller removes the Wails binary, MAPI handler, registry keys, AppUserModelID shortcut, and temp directory; nothing of go-mapi remains after uninstall
  5. A Pester 5 smoke test verifies install and uninstall round-trip on a fresh `windows-latest` CI runner without manual intervention
**Plans**: 6 plans
- [x] 10-01-PLAN.md — NSIS scaffold + MAPI handler + previous-client backup + ApplicationID plugin vendoring + v2.0 artifact cleanup (INST-01, INST-03, INST-04) — completed 2026-04-20
- [x] 10-02-PLAN.md — WebView2 bootstrap in installer + Wails app runtime-missing recovery via MessageBoxW (INST-02) — completed 2026-04-20
- [x] 10-03-PLAN.md — AUMID + Start Menu shortcut + firewall rule (INST-01, INST-06) — completed 2026-04-20
- [x] 10-04-PLAN.md — Uninstall 10-step scrub + Default Mail restore + README multi-user caveat (INST-05) — completed 2026-04-20
- [x] 10-05-PLAN.md — Pester 5 smoke tests + CI smoke workflow + inline-C# AUMID reader (INST-07) — completed 2026-04-20
- [x] 10-06-PLAN.md — Release workflow + SignPath v2 + wails.json info.productVersion (INST-01, INST-03) — completed 2026-04-20

### Phase 11: Autoupdate + Release
**Goal**: Users are notified of new versions via tray notification and can download them with one click; the v3.0 binary is released to a stable URL, the extension is retired from browser stores, and the end-to-end flow is smoke-tested on a clean machine
**Depends on**: Phase 10 foundation, including 10-05 smoke gate and 10-06 release pipeline
**Requirements**: REL-01, REL-02, REL-03, REL-04, REL-05, REL-06, REL-07
**Success Criteria** (what must be TRUE):
  1. When a newer version is available on GitHub Releases, the tray icon shows an update indicator and a notification appears with a "Download" button that opens the release page — no in-process binary replacement occurs
  2. User can toggle off update checks in settings; the toggle persists across restarts and no network calls to GitHub are made while opted out
  3. `go-mapi-setup.exe` is downloadable from `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` and installs successfully on a machine with no prior go-mapi
  4. The Chrome Web Store listing and Edge Add-ons listing for the v2.x extension are frozen/deprecated with strong desktop-app cutover messaging, and proof of the store-side action is captured
  5. An end-to-end smoke test on Windows Sandbox completes: fresh install → sign in → MAPI trigger → email queued → Gmail draft created → uninstall clean; README describes the v3.0 install flow
**Plans**: 6 plans
- [x] 11-01-PLAN.md — Updater backend + persisted AppSettings + App-owned update state/event model (REL-03, REL-05)
- [x] 11-02-PLAN.md — Tray toggle/manual-check/status rows + notify-only Download action (REL-04, REL-05)
- [x] 11-03-PLAN.md — Main-window update banner/panel + typed frontend wrappers/tests (REL-04)
- [ ] 11-04-PLAN.md — Release/docs cutover + stable URL publish + store-retirement evidence checkpoint (REL-01, REL-02, REL-07)
- [ ] 11-05-PLAN.md — Windows Sandbox clean-machine smoke harness + evidence gate (REL-06)
- [x] 11-06-PLAN.md — Playwright/CDP E2E harness — closes UI roundtrip regression class (REL-08; inserted 2026-04-22 after 11-05 manual smoke caught queue-row staleness bugs Vitest mocks could not see; 5/5 specs green, self-verification confirmed Test 2 catches the pre-fix watcher dispatch bug)

### Phase 11.1: Installer hardening + enterprise deploy + silent auto-update (INSERTED)
**Goal**: Ship v3.0 with a complete enterprise-deploy story — an admin can drop a machine config file and run `go-mapi-setup.exe` to get a fleet-ready endpoint that installs system-wide and updates itself unattended, instead of forcing a quick v3.0.1 follow-on. Single-user install is explicitly dropped (MAPI handler registration is inherently machine-wide), so the installer and all its paths are unconditionally All Users.
**Depends on**: Phase 11 (11-01/02/03/06 already shipped — updater backend + tray UI + main-window banner + E2E harness are prerequisites for the config-gated silent-update path)
**Requirements**: TBD (run `/gsd-plan-phase 11.1` to break down)
**Success Criteria** (what must be TRUE):
  1. Installer is system-wide only: `RequestExecutionLevel admin` enforced, `SetShellVarContext all` applied everywhere, Start Menu shortcut lands in `%ProgramData%\Microsoft\Windows\Start Menu\Programs\` (T2 fix), Current User scope removed from NSIS + docs
  2. In-place reinstall succeeds without a manual uninstall step — the 32-bit `go-mapi.dll` overwrite bug (T4) is investigated, root-caused, and fixed with a regression test in the Pester smoke harness
  3. A machine-wide config file at `%PROGRAMDATA%\go-mapi\go-mapi.machine.yaml` is loaded at `NewApp()` startup with admin-only write ACLs enforced at install time; a user-scope `%APPDATA%\go-mapi\go-mapi.user.yaml` layers on top with `locked:` keys respected; effective config is exposed to the frontend via a Wails binding
  4. Both `go-mapi.machine.yaml.example` + `go-mapi.user.yaml.example` ship with inline-documented keys (schema_version, defaults, allowed values, scope, lockability); installer copies machine example to `%PROGRAMDATA%\go-mapi\` (not as the live file) and user example to install dir as documentation
  5. Installer exposes a tri-state Auto-update install option ("None / Notify / Silent") with `Notify` as default; silent auto-update runs via a Windows Scheduled Task under SYSTEM (or a dedicated service account) that downloads + verifies + stages the new binary without elevating the interactive user; `Silent` is gated by the machine config flag and refuses to run if config is absent
  6. CI (`build.yml`) builds + uploads the new installer variants and example config artefacts; README is rewritten with an enterprise-install section covering the tri-state option, the machine config surface, silent-update prerequisites, and the All Users caveat
  7. Pester smoke harness (extends Phase 10's) covers: fresh install with each of the three update modes, reinstall-over-existing, machine config presence verification, uninstaller scrub of `%PROGRAMDATA%\go-mapi\` and the Scheduled Task
**Plans**: TBD (run `/gsd-plan-phase 11.1` to break down)

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Foundation & SignPath Application | v2.0.0 | 8/8 | Complete | 2026-04-10 |
| 2. Extension Install UX | v2.0.0 | 4/4 | Complete | 2026-04-10 |
| 3. Inno Setup Installer + Signing + Distribution | v2.0.0 | 4/4 | Complete | 2026-04-10 |
| 4. Test-Suite Completeness + E2E | v2.0.0 | 4/4 | Complete | 2026-04-10 |
| 5. Release Cut | v2.0.0 | 4/4 | Complete | 2026-04-12 |
| 6. Changesets Monorepo Scaffold | v2.1.0 | 3/3 | Complete | 2026-04-12 |
| 7. Wails Shell + RAM Gate | v3.0 | 4/4 | Complete | 2026-04-14 |
| 8. OAuth + Credentials | v3.0 | 5/5 | Complete | 2026-04-18 |
| 8.1. Post-pivot cleanup and test coverage review (INSERTED) | v3.0 | 9/9 | Complete | 2026-04-19 |
| 9. Queue, Automode + Toasts | v3.0 | 9/9 | Complete | 2026-04-19 |
| 10. Installer + Migration | v3.0 | 6/6 | Complete | 2026-04-20 |
| 11. Autoupdate + Release | v3.0 | 0/? | Not started | - |
| 11.1. Installer hardening + enterprise deploy + silent auto-update (INSERTED) | v3.0 | 0/? | Not started | - |

---
*Roadmap updated: 2026-04-24 — Phase 11.1 inserted (installer hardening + enterprise deploy + silent auto-update). Phase 11's remaining 11-04 Task 2+3 (store delisting + GA tag) sequence AFTER v3.0 ships and `go-mapi-www` is live — explicitly non-blocking.*
