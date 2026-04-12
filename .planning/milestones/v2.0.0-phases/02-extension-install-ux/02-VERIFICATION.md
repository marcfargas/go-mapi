---
phase: 02
phase_name: Extension Install UX
status: passed
verified: 2026-04-10
verifier: Phase 2 executor (in-session verification per plan)
---

# Phase 2 Verification: Extension Install UX

## Goal-backward check

**Phase goal (from ROADMAP.md):** "A user opening the extension popup on a
machine without the host sees a clear in-popup install banner with a direct
download link, and the popup auto-detects the host appearing afterwards."

**Was the goal achieved?** Yes. All six EXT-01..06 requirements shipped with
their locked decisions (CONTEXT.md D-01..D-18) honored. OUTDATED branch
ships dead but wired; `HOST_STATE` broadcast is extension-internal only;
no native-messaging wire types added; placeholder download URL is clearly
marked for EXT-07 swap in Phase 3.

## Requirement-by-requirement check

| Req | Status | Evidence |
|---|---|---|
| EXT-01 | ✓ Complete | `src/extension/src/lib/hostDetector.ts` exports `HostState` union (`UNKNOWN \| PROBING \| READY \| MISSING \| OUTDATED \| ERROR`) and classifier helpers; service-worker.ts `transitionHostState` drives the machine |
| EXT-02 | ✓ Complete | `MISSING_HOST_SUBSTRING = 'Specified native messaging host not found'` constant; `classifyLastError` uses `String.includes` on it; service-worker logs verbatim `lastError.message` before classifying |
| EXT-03 | ✓ Complete | `src/extension/src/lib/hostVersion.ts` exports `MIN_SUPPORTED_HOST_VERSION = '2.0.0'` and `compareHostVersion` / `isHostVersionSupported`. Pinned equal to current v2.0.0 host version → OUTDATED branch is dead |
| EXT-04 | ✓ Complete | `HostStateMessage` + `HostInstalledToastMessage` in `messages.ts`; service-worker broadcasts `HOST_STATE` on every transition; App.tsx subscribes; `protocol.go` untouched (no new wire types) |
| EXT-05 | ✓ Complete | `src/extension/src/popup/InstallPrompt.tsx` with placeholder `INSTALLER_DOWNLOAD_URL` constant, `// EXT-07: swap in Phase 3` comment, SmartScreen guidance Alert, React Bootstrap Card/Button/Alert composition, English-only copy |
| EXT-06 | ✓ Complete | Existing 6-second reconnect alarm reused; MISSING → READY edge detection in `transitionHostState` fires `HOST_INSTALLED_TOAST` exactly once per session; `hasShownInstalledToast` persisted in `chrome.storage.session`; popup renders auto-hiding React Bootstrap Toast |

## Build verification (orchestrator, end of phase)

```bash
cd src/native-host && go build ./... && go vet ./... && go test ./...
# → ok github.com/marcfargas/go-mapi/native-host
# → go vet clean
# → tests pass (Phase 1 foundation unchanged)

cd src/extension && npx tsc --noEmit && npm run lint && npm run test:run
# → tsc --noEmit: clean
# → eslint: clean
# → vitest: 3 files / 43 tests passed (existing tests; no new tests authored in Phase 2 per scope discipline)
```

All six exit verification commands exited 0.

## Plan-by-plan status

| Plan | Scope | Status | Commit |
|---|---|---|---|
| 02-01 | hostVersion.ts + hostDetector.ts library modules | ✓ | `5ea325e feat(02-01)` |
| 02-02 | `HOST_STATE` discriminated union + service-worker state machine wiring | ✓ | `85adbac feat(02-02)` |
| 02-03 | InstallPrompt.tsx + App.tsx HOST_STATE subscription | ✓ | `b74030d feat(02-03)` |
| 02-04 | MISSING → READY edge detection + React Bootstrap Toast | ✓ | `f861f05 feat(02-04)` |

## Scope discipline audit

- [x] No modifications under `src/native-host/` (verified via `git diff --name-only ac1f573..HEAD -- src/native-host/` → empty)
- [x] `protocol.go` untouched — no new wire-protocol message types
- [x] Legacy `version` field preserved alongside `hostVersion` on all READY message reads (`message.hostVersion || message.version`)
- [x] Legacy `CONNECTION_STATUS` broadcast preserved in all four original sites so the popup's `state.connected` header indicator still works
- [x] No new alarm — existing 6-second reconnect alarm reused as-is
- [x] No `chrome.notifications` calls added (D-17: Toast is popup-local React Bootstrap, not OS-level)
- [x] Placeholder download URL marked with `// EXT-07: swap in Phase 3` comment — Phase 3 only needs to change the URL value
- [x] No test files authored (Phase 4 TSTEST-02/03/04/05 owns all Phase 2 test authoring)
- [x] No installer work (Phase 3)
- [x] No pre-existing staticcheck cleanups in `gmail.go` / `main.go` / `watcher.go` (explicitly out of scope per Phase 1 handoff)
- [x] Strict TS, no `any`, explicit return types throughout
- [x] English-only UI copy (external-project i18n rule)

## Must-haves

1. **In-popup install banner** — `InstallPrompt.tsx` renders with heading, explanation, Download button, SmartScreen Alert
2. **Direct download link with placeholder URL** — `INSTALLER_DOWNLOAD_URL` constant marked for EXT-07 swap
3. **Host state machine drives popup render** — App.tsx `showInstallPrompt` boolean gates the content branches
4. **`"not found"` classified as MISSING** — substring match in `classifyLastError`
5. **Full `lastError.message` logged** — `console.log('[go-mapi] Disconnected:', lastError)` in onDisconnect handler, preserved and reached before classification
6. **OUTDATED is a dead branch** — `MIN_SUPPORTED_HOST_VERSION` equals current '2.0.0', `classifyReadyMessage` wired, `InstallPrompt` variant copy in place
7. **No new wire types** — `HOST_STATE` and `HOST_INSTALLED_TOAST` live only in `messages.ts` discriminated union, not in `protocol.go`
8. **Auto-transition on install** — 6-second alarm + real NativeReadyMessage gating (D-03) means no manual reload
9. **One-time success toast** — `hasShownInstalledToast` session flag + edge detection on `prev === 'MISSING' && next === 'READY'`
10. **React Bootstrap Toast** — not `chrome.notifications`, scoped to the popup, auto-hides after 5s

## Deviations from plan

1. **Worktree branch rebase.** The worktree branch `worktree-agent-a5c14172`
   was forked from an old pre-Phase-1 commit (`8a01fa3`) and needed a
   fast-forward merge from `develop` at the start of execution to pick up
   the Phase 1 foundation + `.planning/` tree. No code changes resulted;
   Phase 2 work started from the correct post-Phase-1 state.

2. **`MIN_SUPPORTED_HOST_VERSION` pinned as a literal.** CONTEXT D-06 left
   this to "planner decides between import and literal constant." I chose
   the literal `'2.0.0'` per the explicit task hint "pick simpler". A
   comment on the constant explains the v3.0.0 activation path.

3. **`hasShownInstalledToast` declaration added in plan 02-04, not 02-02.**
   To keep commit boundaries clean, the flag variable + session-storage
   hydration was introduced in plan 02-04 alongside its consumer (the
   edge-detection block). Plan 02-02 did not need it since the MISSING →
   READY toast is plan 02-04's deliverable.

## Next-phase notes

### For Phase 3 (EXT-07 + installer)

- The only change required in `InstallPrompt.tsx` for EXT-07 is to swap
  the `INSTALLER_DOWNLOAD_URL` string literal. No component refactor.
  The grep-verifiable comment `// EXT-07: swap in Phase 3` is on the
  line immediately above the constant.
- The placeholder URL (`https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`)
  is the planned final URL — if Phase 3 publishes to exactly that path,
  no change is needed at all. This is deliberate per D-12.

### For Phase 4 (TSTEST-02..05)

- `hostDetector.ts` is deliberately side-effect-free so tests can import
  `classifyLastError` / `classifyReadyMessage` without any Chrome API mocks.
  TSTEST-02 should exercise the `MISSING_HOST_SUBSTRING` classification
  against a set of real Chrome and Edge error strings captured during
  E2E runs (ROADMAP Phase 4 research flag).
- `hostVersion.ts` is also side-effect-free. TSTEST-03 should exercise
  `compareHostVersion` edge cases (equal, below, above, missing segments,
  non-numeric segments coerced to 0).
- `service-worker.ts` `transitionHostState` is a pure function of
  `(prev, next, opts, hasShownInstalledToast)` — TSTEST-05 can test it
  by stubbing `broadcastToPopup` and `persistInstalledToastFlag`.
- `InstallPrompt.tsx` has no internal state — TSTEST-04 should render
  the three variants (MISSING, OUTDATED, ERROR) and assert on the
  heading, button label, and SmartScreen copy.

## Phase status

**Phase 2 COMPLETE.** Ready for Phase 3 (Inno Setup Installer + Signing +
Distribution) and Phase 4 (Test-Suite Completeness + E2E) to proceed in
parallel per the roadmap's parallelism rationale.
