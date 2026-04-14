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
- [ ] **Phase 8: OAuth + Credentials** — Desktop OAuth (PKCE loopback) with Windows Credential Manager storage; Google verification submitted day 1 [UNBLOCKED by Phase 7 PASS]
- [ ] **Phase 9: Queue, Automode + Toasts** — Email queue UI, Manual/Auto-draft toggle, and Windows toast notifications
- [ ] **Phase 10: Installer + Migration** — NSIS installer with AppUserModelID, WebView2 bootstrap, v2.x cleanup, and uninstall
- [ ] **Phase 11: Autoupdate + Release** — Notify-only autoupdate, GitHub release pipeline, extension store retirement, smoke test

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
**Plans**: TBD

### Phase 9: Queue, Automode + Toasts
**Goal**: Users can view queued emails in the main window, act on them individually, set an automatic draft mode, and receive Windows toast notifications when new emails arrive
**Depends on**: Phase 8
**Requirements**: QUEUE-01, QUEUE-02, QUEUE-03, QUEUE-04, QUEUE-05, QUEUE-06, QUEUE-07, NOTIF-01, NOTIF-02, NOTIF-03, NOTIF-04, NOTIF-05
**Success Criteria** (what must be TRUE):
  1. The main window lists all pending emails showing sender, subject, attachment count, and timestamp; the list updates live when files appear in `%TEMP%\go-mapi\` without requiring a window refresh
  2. User can click "Create draft" on any email and a Gmail draft appears; user can click "Dismiss" to remove an email from the queue without drafting
  3. In Auto-draft mode, every new queued email becomes a Gmail draft automatically — including while the window is hidden; failed auto-drafts stay in the queue with a visible error state and a notification
  4. A Windows toast notification appears when a new email arrives in the queue, showing sender and subject only (no body text); toast action buttons allow "Create draft" or "Dismiss" without opening the main window
  5. The Auto-draft / Manual mode toggle persists across app restarts
**Plans**: TBD
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
**Plans**: TBD

### Phase 11: Autoupdate + Release
**Goal**: Users are notified of new versions via tray notification and can download them with one click; the v3.0 binary is released to a stable URL, the extension is retired from browser stores, and the end-to-end flow is smoke-tested on a clean machine
**Depends on**: Phase 10
**Requirements**: REL-01, REL-02, REL-03, REL-04, REL-05, REL-06, REL-07
**Success Criteria** (what must be TRUE):
  1. When a newer version is available on GitHub Releases, the tray icon shows an update indicator and a notification appears with a "Download" button that opens the release page — no in-process binary replacement occurs
  2. User can toggle off update checks in settings; the toggle persists across restarts and no network calls to GitHub are made while opted out
  3. `go-mapi-setup.exe` is downloadable from `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` and installs successfully on a machine with no prior go-mapi
  4. The Chrome Web Store listing and Edge Add-ons listing for the v2.x extension are unpublished
  5. An end-to-end smoke test on Windows Sandbox completes: fresh install → sign in → MAPI trigger → email queued → Gmail draft created → uninstall clean; README describes the v3.0 install flow
**Plans**: TBD

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Foundation & SignPath Application | v2.0.0 | 8/8 | Complete | 2026-04-10 |
| 2. Extension Install UX | v2.0.0 | 4/4 | Complete | 2026-04-10 |
| 3. Inno Setup Installer + Signing + Distribution | v2.0.0 | 4/4 | Complete | 2026-04-10 |
| 4. Test-Suite Completeness + E2E | v2.0.0 | 4/4 | Complete | 2026-04-10 |
| 5. Release Cut | v2.0.0 | 4/4 | Complete | 2026-04-12 |
| 6. Changesets Monorepo Scaffold | v2.1.0 | 3/3 | Complete | 2026-04-12 |
| 7. Wails Shell + RAM Gate | v3.0 | 0/? | Not started | - |
| 8. OAuth + Credentials | v3.0 | 0/? | Not started | - |
| 9. Queue, Automode + Toasts | v3.0 | 0/? | Not started | - |
| 10. Installer + Migration | v3.0 | 0/? | Not started | - |
| 11. Autoupdate + Release | v3.0 | 0/? | Not started | - |

---
*Roadmap updated: 2026-04-12 — v3.0 Wails Pivot phases 7-11 defined*
