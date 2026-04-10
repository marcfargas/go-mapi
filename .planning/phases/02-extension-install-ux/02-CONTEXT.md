# Phase 2: Extension Install UX - Context

**Gathered:** 2026-04-10 (assumptions/auto mode)
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver EXT-01 through EXT-06: when a user opens the extension popup on a machine without the native host installed, they see a clear in-popup install banner with a direct download link (placeholder URL in this phase); when the host appears afterwards, the popup auto-transitions from `MISSING` to `READY` within one reconnect cycle and shows a one-time success toast — no manual reload.

**In scope:** host detector state machine, host version gate module (dead branch), internal `HOST_STATE` broadcast, `InstallPrompt.tsx`, reconnect-alarm success-toast logic.

**Out of scope:** real installer URL swap (EXT-07 → Phase 3), installer itself (Phase 3), extension test writing (TSTEST-* → Phase 4), Chrome Web Store listing, any new native-messaging wire types.

</domain>

<decisions>
## Implementation Decisions

### State Machine (EXT-01, EXT-02)
- **D-01:** New module `src/extension/src/lib/hostDetector.ts` owns the state machine `UNKNOWN → PROBING → { READY | MISSING | OUTDATED | ERROR }`. Transitions are driven by `chrome.runtime.connectNative` outcome, `chrome.runtime.lastError.message`, and the incoming `READY` message from the host.
- **D-02:** `MISSING` is classified on the substring match `"Specified native messaging host not found"` in `chrome.runtime.lastError.message`. The full `lastError.message` is logged (not just the classified label) for forward compatibility with future Chrome phrasing changes.
- **D-03:** `READY` is gated on actually receiving a `NativeReadyMessage` from the port — a successful `connectNative` call alone is not enough. This closes the race where Chrome opens the port before the host handshakes.
- **D-04:** `ERROR` is reserved for unexpected `lastError` values that don't match `MISSING`. The error message is logged verbatim and the popup shows a generic "host error" state (reuses the install prompt copy with a note to check logs — keeps Phase 2 surface area minimal).

### Host Version Gate (EXT-03)
- **D-05:** New module `src/extension/src/lib/hostVersion.ts` exports `MIN_SUPPORTED_HOST_VERSION` and a `compareHostVersion(current, minimum)` helper using simple semver-compatible comparison (split on `.`, numeric compare of major/minor/patch; no pre-release handling needed — host versions are plain `x.y.z`).
- **D-06:** `MIN_SUPPORTED_HOST_VERSION` is set equal to the current host version shipped in this release (read from `package.json` root or pinned literal — planner decides between import and literal constant, but the value must equal the current release so `OUTDATED` is a dead branch).
- **D-07:** The `OUTDATED` branch ships as dead code: the comparator is wired, tests exist, but because min == current, the branch is unreachable in v2.0.0. This is deliberate — activation in v3.0.0 requires only bumping `MIN_SUPPORTED_HOST_VERSION`, no wire-protocol change.

### Internal Broadcast (EXT-04)
- **D-08:** The service worker broadcasts a new internal `HOST_STATE` message (`chrome.runtime.sendMessage` pattern already used for `emails`/`recentDrafts`) on every detector state transition. Payload shape: `{ action: 'HOST_STATE', state: HostState, hostVersion?: string, errorMessage?: string }`.
- **D-09:** The `HOST_STATE` type is added to `src/extension/src/types/messages.ts` alongside the existing internal message types — NOT added to the native-messaging wire protocol (`protocol.go` is untouched). Phase 1 Decision #3 locks this in.
- **D-10:** The popup subscribes to `HOST_STATE` via the existing `chrome.runtime.onMessage` listener in `App.tsx`, stores the state in React state, and renders conditionally: `READY` → existing email queue UI, `MISSING`/`ERROR` → `InstallPrompt`, `OUTDATED` → install prompt variant (dead branch).

### Install Prompt Component (EXT-05)
- **D-11:** New component `src/extension/src/popup/InstallPrompt.tsx` renders when state is `MISSING`. Content: short heading ("Install the go-mapi host"), one-line explanation, direct download button, brief SmartScreen guidance (1–2 sentences explaining the "Windows protected your PC" prompt the user will see on the unsigned `.exe`), and no GitHub redirect.
- **D-12:** The download URL is a named constant `INSTALLER_DOWNLOAD_URL` at the top of `InstallPrompt.tsx` with a clear `// EXT-07: swap in Phase 3` comment. Placeholder value: `'https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe'` (the planned final URL — using the real URL as placeholder means Phase 3 only changes if the URL format changes, not every time).
- **D-13:** Styling reuses existing React Bootstrap components (`Card`, `Button`, `Alert` for SmartScreen note) to match the existing popup look and avoid adding CSS.
- **D-14:** Copy is English-only (this is an external project per user's global i18n rule).

### Host-Appears-After-Install Flow (EXT-06)
- **D-15:** Reuse the existing 6-second reconnect alarm in the service worker (no new alarm). On each tick while state is `MISSING`, the detector attempts `connectNative` again and runs the same classification logic.
- **D-16:** Success is gated on `READY` message arrival, not on `connectNative` success — same gate as D-03. Only when a `READY` with a valid `hostVersion` arrives does the detector transition `MISSING → READY`.
- **D-17:** On the `MISSING → READY` edge, the service worker posts an internal `HOST_STATE` broadcast AND a one-time `HOST_INSTALLED_TOAST` message. The popup (if open) renders a dismissible React Bootstrap `Toast` for ~5 seconds. If the popup is closed, the toast is dropped (no `chrome.notifications` — the success is obvious when the user next opens the popup and sees the email queue).
- **D-18:** The `MISSING → READY` toast fires only once per session: tracked via a `hasShownInstalledToast` flag in `chrome.storage.session` (consistent with existing session-storage pattern). Reset on service worker restart is acceptable.

### Claude's Discretion
- Exact RB component composition inside `InstallPrompt.tsx`.
- Exact copy wording for the install prompt and SmartScreen note (keep it short, factual, non-technical).
- Internal helper names, file-level comments, test layout within existing `__tests__/` folders (Phase 2 is non-test-writing per Phase 1 handoff, but minimal type-safety checks welcome).
- Whether `HostState` is a string-union type or a string enum — pick whichever reads cleanest in React.
- Dead-branch rendering for `OUTDATED` — minimal stub that reuses `InstallPrompt` variant with different copy is fine.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope + requirements
- `.planning/ROADMAP.md` §"Phase 2: Extension Install UX" — goal, success criteria, dependency on Phase 1 FOUND-02.
- `.planning/REQUIREMENTS.md` EXT-01 through EXT-06 (lines 23–28) — full requirement text. EXT-07 is explicitly Phase 3, not Phase 2.
- `.planning/phases/01-foundation-signpath-application/.continue-here.md` — Phase 1 handoff; lists 5 decisions Phase 2 must honor, essential reads, and verification commands.

### Phase 1 foundations this phase builds on
- `.planning/phases/01-foundation-signpath-application/01-02-SUMMARY.md` — FOUND-02 `hostVersion` field added to `NativeReadyMessage`.
- `src/native-host/protocol.go` — `READY` message shape (reference only, NOT modified in Phase 2).
- `src/native-host/version.go` — current host version source (for picking `MIN_SUPPORTED_HOST_VERSION` value).

### Existing extension code to modify/extend
- `src/extension/src/background/service-worker.ts` — port management, existing 6-second reconnect alarm, `hostVersion` variable at line 17, `READY` handler at lines 107–108.
- `src/extension/src/popup/App.tsx` — popup root; add `HOST_STATE` subscription + conditional render.
- `src/extension/src/types/messages.ts` — `NativeReadyMessage` at line 65; add internal `HostStateMessage` and `HostInstalledToastMessage` here (lines ~92 in the union type).

### Project conventions
- `CLAUDE.md` §"Extension UI and logic" — React 18 + React Bootstrap + Vite single-pass bundling, strict TS, no `any`.
- User global i18n rule: external projects ship English UI only.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `src/extension/src/background/service-worker.ts`: existing port lifecycle, reconnect alarm, and `hostVersion` capture on `READY` — hook new detector into the existing alarm rather than adding a second timer.
- `src/extension/src/types/messages.ts`: internal message union already exists — `HostStateMessage` and `HostInstalledToastMessage` slot into the same union. `NativeReadyMessage.hostVersion` is already optional (FOUND-02) and ready to consume.
- `src/extension/src/popup/App.tsx`: existing `chrome.runtime.onMessage` listener and `getEmails` bootstrap call — new `HOST_STATE` subscription piggybacks on the same listener.
- React Bootstrap `Card`, `Button`, `Alert`, `Toast` components already used elsewhere in the popup — no new UI dependencies.

### Established Patterns
- Session-scoped state persistence via `chrome.storage.session` (used for `emails` and `recentDrafts`) — new `hasShownInstalledToast` flag follows the same pattern.
- Internal extension messages use `chrome.runtime.sendMessage({ action: 'STRING', ... })` shape — `HOST_STATE` follows this.
- Logging format: `console.log('[go-mapi] ...')` — applies to detector state transitions and classified `lastError` messages.
- Tests live under `__tests__/` co-located with the module being tested.

### Integration Points
- Service worker `onMessage` from native port → detector state transition → `HOST_STATE` broadcast → popup re-render.
- Reconnect alarm (6s) → detector re-probe → `connectNative` → either stays `MISSING` or fires `READY` handler which transitions to `READY`.
- Popup `App.tsx` switches on `HostState` to render either the existing email queue or `InstallPrompt`.

</code_context>

<specifics>
## Specific Ideas

- Phase 1 handoff explicitly locks: no new wire protocol types, keep legacy `version` field alongside `hostVersion`, placeholder download URL is fine for Phase 2, and `MIN_SUPPORTED_HOST_VERSION == current host version` so OUTDATED ships dead.
- SmartScreen guidance copy is required by success criterion #1 — short enough to fit in the popup (popup is narrow, ~360px).
- The "one-time success toast" is a React Bootstrap `Toast`, not a `chrome.notifications` OS-level notification — success is local to the popup.

</specifics>

<deferred>
## Deferred Ideas

- **EXT-07 real installer URL swap** — Phase 3, after installer is published and the stable GitHub Releases URL is confirmed.
- **Writing tests for `hostDetector` and the `HOST_STATE` broadcast** — Phase 4 (TSTEST-02, TSTEST-05). Phase 2 ships implementation only; test authoring is explicitly Phase 4 per the handoff.
- **Activating the `OUTDATED` branch** — v3.0.0, by bumping `MIN_SUPPORTED_HOST_VERSION`. No work in Phase 2 beyond ensuring the branch compiles and is reachable via the comparator in tests.
- **Chrome Web Store listing + publication** — out of roadmap entirely.
- **Staticcheck cleanups in `gmail.go` / `main.go` / `watcher.go`** — pre-existing tech debt, surfaced in Phase 1 handoff, explicitly out of scope.

</deferred>

---

*Phase: 02-extension-install-ux*
*Context gathered: 2026-04-10 (assumptions/auto mode)*
