# Architecture Research

**Domain:** Windows installer + extension handshake + test infrastructure, layered onto existing three-tier MAPI bridge
**Researched:** 2026-04-10
**Confidence:** HIGH for installer tooling / registry layout / handshake protocol (Context7-class official docs). MEDIUM for Playwright-on-native-messaging specifics (extension-only tests are well documented; driving the native host end-to-end through Playwright is less well-trodden and the recommended approach here is a hybrid test harness rather than "Playwright does everything").

> **Scope reminder.** This document does NOT re-design the v1.0.0 bridge. It describes the *new* components v2.0.0 adds — installer binary, extension-side install/handshake UX, and test infrastructure — and how they attach to what already exists (see `.planning/codebase/ARCHITECTURE.md`).

---

## 1. System Overview (v2.0.0 additions in context)

```
┌──────────────────────────────────────────────────────────────────────────┐
│                       EXISTING v1.0.0 BRIDGE (unchanged)                  │
│                                                                            │
│   Win App ── MAPISendMail() ──▶  go-mapi.dll                              │
│                                      │                                    │
│                                      ▼  writes JSON                       │
│                             %TEMP%\go-mapi\*.json                          │
│                                      │                                    │
│                                      ▼  fsnotify                          │
│                             go-mapi-host.exe (Go)                          │
│                                      │                                    │
│                                      ▼  native messaging (stdio)          │
│                             Extension SW  ──▶  Popup (React)              │
│                                      │                                    │
│                                      ▼  HTTPS                              │
│                             Gmail API /drafts                              │
│                                                                            │
└──────────────────────────────────────────────────────────────────────────┘
                    ▲                                      ▲
                    │                                      │
                    │ writes files + registry              │ reads host state,
                    │                                      │ drives install UX
                    │                                      │
┌───────────────────┴──────────┐       ┌───────────────────┴───────────────┐
│   NEW: Windows Installer     │       │   NEW: Extension Install UX       │
│   (go-mapi-setup-X.Y.Z.exe)  │       │   (host-detection + handshake)    │
│                              │       │                                   │
│   Built from src/installer/  │       │   Lives inside service-worker.ts  │
│   via Inno Setup 6 + ISCC    │       │   + new popup install page        │
└──────────────────────────────┘       └───────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│                       NEW: Test Infrastructure                            │
│                                                                            │
│   tests/e2e/           Playwright harness (extension + mock host)          │
│   tests/fixtures/      Golden MAPI JSON files (shared C++/Go/TS)           │
│   tests/installer/     Pester smoke tests for installer output             │
│   src/interceptor/test-harness/  (existing, expand)                        │
│   src/native-host/*_test.go      (existing, expand + -race in CI)          │
│   src/extension/src/**/__tests__ (existing, expand)                        │
└──────────────────────────────────────────────────────────────────────────┘
```

### New Component Responsibilities

| Component | Responsibility | Implementation | Lives in |
|-----------|----------------|----------------|----------|
| **Installer binary** (`go-mapi-setup-X.Y.Z.exe`) | Elevate, place files under `C:\Program Files\go-mapi`, render manifest templates with the real exe path, write Chrome + Edge native-messaging registry keys, write MAPI handler registry keys, write uninstall metadata. | Inno Setup 6 script + small Pascal `[Code]` section for manifest templating and extension-ID capture. No custom DLL. | `src/installer/` (see §2) |
| **Installer uninstall path** | Remove files, remove all 4 registry key families, remove residual `%TEMP%\go-mapi\` if empty, restore previous Mail client registration if we captured one. | Same Inno Setup script via `[UninstallRun]` / `[UninstallDelete]` and a small `[Code]` uninstall step. | `src/installer/` |
| **Host-detection module** (`hostDetector.ts`) | Pure function + state machine: `UNKNOWN → PROBING → MISSING | OUTDATED | READY`. Wraps `chrome.runtime.connectNative`, classifies `onDisconnect` errors, compares `READY.version` to a minimum supported host version. | Tiny TS module, no React, fully unit-testable with the existing `chrome.ts` mock. | `src/extension/src/lib/hostDetector.ts` |
| **Install prompt UI** | Popup view shown when host state is `MISSING` or `OUTDATED`. Button → `chrome.tabs.create({ url: INSTALLER_URL })`. Listens for state transitions and renders the success toast. | New React component, follows existing popup conventions (React-Bootstrap). | `src/extension/src/popup/InstallPrompt.tsx` |
| **Success-toast watcher** | Background alarm that keeps retrying `connectNative` after an `InstallPrompt` is shown, and on first `READY` arrival posts a `chrome.notifications` success toast and auto-navigates the popup back to the queue view. | Extension of existing reconnect alarm in `service-worker.ts` — do not add a second polling loop. | `src/extension/src/background/service-worker.ts` |
| **Mock native host** (test double) | Stdio binary that speaks the native-messaging framing, emits scripted `READY` / `EMAIL` / `DRAFT_CREATED` messages from a fixture file. Used by Playwright E2E and by extension integration tests. | Small Go program sharing `src/native-host/protocol.go` types. | `tests/e2e/mock-host/` (Go main, ~150 LOC) |
| **E2E runner** | Playwright test that launches Chromium with `--load-extension=src/extension/dist`, registers a per-user native-messaging manifest pointing at the mock host, drops fixture JSON into a temp watch dir, and asserts popup UI outcomes. | Playwright + a small TS setup helper. Uses the real service worker, real popup, real protocol — only the DLL is replaced by a file drop. | `tests/e2e/` |
| **Installer smoke tests** | Pester scripts that install the real `.exe` silently into a sandbox dir, verify every expected registry key + file is present, verify version-coded manifest contents, then uninstall and verify everything is gone. | Pester 5 + `runas` in a GitHub Actions Windows runner. | `tests/installer/` |

---

## 2. Repository Layout (proposed additions)

Only **new or modified** paths are shown; everything else from `STRUCTURE.md` stays as-is.

```
go-mapi/
├── src/
│   ├── installer/                             # NEW — Inno Setup sources
│   │   ├── go-mapi-setup.iss                  # main Inno Setup script (references built artifacts)
│   │   ├── code/
│   │   │   ├── extension_id.iss               # [Code] block: capture or auto-detect extension ID
│   │   │   ├── manifests.iss                  # [Code] block: write Chrome + Edge manifests from template
│   │   │   └── prev_mail_client.iss           # [Code] block: backup/restore HKLM Mail default
│   │   ├── assets/
│   │   │   ├── license.txt                    # LGPL-3.0 notice shown in installer
│   │   │   ├── icon.ico                       # installer icon
│   │   │   └── banner.bmp                     # optional 164x314 wizard banner
│   │   ├── build.ps1                          # invokes ISCC.exe with version from package.json
│   │   └── README.md                          # how to build the installer locally
│   │
│   ├── native-host/
│   │   ├── version.go                         # NEW — single source of truth for host version constant
│   │   └── manifests/
│   │       ├── com.gomapi.host.chrome.json.tmpl   # RENAMED + templated (path + ext id placeholders)
│   │       └── com.gomapi.host.edge.json.tmpl
│   │
│   └── extension/
│       └── src/
│           ├── lib/
│           │   ├── hostDetector.ts            # NEW — state machine + connectNative wrapper
│           │   ├── hostVersion.ts             # NEW — MIN_SUPPORTED_HOST_VERSION, semver compare
│           │   └── __tests__/
│           │       ├── hostDetector.test.ts
│           │       └── hostVersion.test.ts
│           ├── popup/
│           │   ├── InstallPrompt.tsx          # NEW — the "host missing/outdated" view
│           │   └── __tests__/
│           │       └── InstallPrompt.test.tsx
│           └── background/
│               └── service-worker.ts          # MODIFIED — integrates hostDetector, success toast
│
├── tests/
│   ├── e2e/
│   │   ├── playwright.config.ts               # EXISTING (currently empty shell) — populate
│   │   ├── fixtures/
│   │   │   ├── simple-email.json              # golden MAPI JSON
│   │   │   ├── email-with-attachment.json
│   │   │   └── README.md                      # shared with Go + C++ test harness
│   │   ├── mock-host/
│   │   │   ├── main.go                        # stdio binary, reads scripted scenario
│   │   │   ├── scenarios/
│   │   │   │   ├── happy-path.json
│   │   │   │   ├── missing-host.json          # scenario marker: "don't register, let test observe MISSING"
│   │   │   │   └── outdated-host.json         # returns READY with old version string
│   │   │   └── go.mod                         # or share root go.mod — see §8
│   │   ├── helpers/
│   │   │   ├── registerMockHost.ts            # writes a scoped HKCU manifest before the test
│   │   │   ├── dropFixture.ts                 # writes JSON into the watched temp dir
│   │   │   └── extensionHandle.ts             # Playwright service-worker + extension-ID retrieval
│   │   └── specs/
│   │       ├── install-ux.spec.ts             # MISSING → install prompt → simulated install → READY toast
│   │       ├── happy-path.spec.ts             # fixture drop → queue update → draft creation (mocked Gmail)
│   │       └── version-mismatch.spec.ts
│   │
│   └── installer/                             # NEW — Pester 5
│       ├── install.smoke.Tests.ps1
│       ├── uninstall.smoke.Tests.ps1
│       └── helpers/
│           └── SandboxInstall.psm1            # installs to $env:TEMP\go-mapi-smoke\
│
├── scripts/
│   ├── install.ps1                            # KEEP for developers; mark as "developer install" in README
│   └── build-installer.ps1                    # NEW — orchestrates: build DLL → build host → build extension → run ISCC
│
└── .github/workflows/
    ├── ci.yml                                 # MODIFIED — add -race, add TS component tests job
    ├── installer.yml                          # NEW — builds + smoke-tests installer on Windows runner
    └── e2e.yml                                # NEW — builds extension, builds mock host, runs Playwright
```

### Layout Rationale

- **`src/installer/` not `installer/` or `scripts/`.** The installer is first-class source code that produces a shipped binary (`go-mapi-setup-X.Y.Z.exe`) — it belongs alongside the other three components under `src/`. `scripts/` is already used for *dev* tooling (`install.ps1`, `package-extension.ps1`); mixing a shipped artifact with dev tooling would blur the line. This matches the existing convention where each built artifact has one directory under `src/`.
- **`src/native-host/manifests/*.tmpl`.** The current files (`com.gomapi.host.chrome.json`, `com.gomapi.host.edge.json`) contain a hard-coded `path` and a `EXTENSION_ID_PLACEHOLDER`. Renaming to `.tmpl` makes their templated nature explicit and signals that the installer (not the build) is responsible for rendering them. Keep them in `src/native-host/` because they describe the host, not the installer.
- **`src/extension/src/lib/hostDetector.ts` not in `background/`.** The service worker is already ~325 lines in one file; stuffing a state machine in there bloats it further and makes it untestable. `lib/` already holds `gmail.ts` (Chrome Identity wrapper) — `hostDetector.ts` is the same shape of thing: a small, pure-ish wrapper around a Chrome API, imported by the service worker.
- **`tests/e2e/` (repo root) not `src/extension/tests/e2e/`.** E2E covers *all three* components (DLL via file-drop fixture, Go host via the real binary, extension via Playwright). It doesn't belong under any single component's tree. This also matches the empty `tests/e2e/playwright.config.ts` shell that already exists in the repo.
- **`tests/e2e/fixtures/` is the single source of truth for golden JSON.** The C++ test-harness (`src/interceptor/test-harness/`) and the Go `watcher_test.go` should both consume these fixtures via a relative path rather than each keeping their own copy. This prevents drift between what the DLL produces, what the watcher parses, and what the E2E asserts.
- **`tests/installer/` (Pester) separate from `tests/e2e/` (Playwright).** Different runners, different dependencies, different speed tiers. Installer smoke tests run fast on every PR; E2E runs slower and only on PRs that touch `src/extension/**` or `src/native-host/**`.

---

## 3. Installer Runtime Behavior

### Why Inno Setup

- **FOSS-friendly.** Inno Setup is free, open source (modified BSD), actively maintained, and ships no telemetry. Matches the LGPL / EU-FOSS-first posture.
- **Script-based, reviewable.** The entire installer is a single `.iss` file plus a Pascal `[Code]` block — fits in code review, diffs cleanly in git, no GUI-only state.
- **Registry + manifest templating + uninstall all in one tool.** No need to compose multiple tools (WiX + a separate updater, say). The Pascal `[Code]` block can read the extension ID from a text box and rewrite the manifest JSON inline before installation.
- **Elevation handled by the tool.** Inno Setup's `PrivilegesRequired=admin` does the right UAC prompt without custom code.
- **Rejected alternatives:** WiX (heavier, XML-verbose, worse DX for a solo maintainer); NSIS (custom-scripting feels dated, weaker modern-Windows integration); MSIX (Microsoft-account sign-in required for side-loading, awkward for OSS distribution without a store listing).

### Elevation Model

- **`PrivilegesRequired=admin`** — the installer elevates once at the start.
- **Rationale.** We write the MAPI handler under `HKLM\SOFTWARE\Clients\Mail\go-mapi`; HKLM requires admin. Native messaging manifests *could* go under HKCU (see `textslashplain.com` and the Chrome developer docs), but keeping everything under HKLM means one elevation prompt and one install for all local users of that machine — which matches the "non-technical Windows user" target.
- **Per-machine install,** not per-user. Default install dir `C:\Program Files\go-mapi\` (already the v1.0.0 convention). All four registry key families written under HKLM.

### File Layout After Install

```
C:\Program Files\go-mapi\
├── go-mapi.dll                      # C++ interceptor
├── go-mapi-host.exe                 # Go native host
├── manifests\
│   ├── com.gomapi.host.chrome.json  # rendered from .tmpl with real path + ext id
│   └── com.gomapi.host.edge.json
├── uninst\
│   ├── unins000.exe                 # Inno Setup's uninstaller
│   ├── unins000.dat                 # Inno Setup's install log
│   └── previous-mail-client.json    # our own backup of the pre-install default mail client, if any
├── LICENSE.txt
└── VERSION                          # plain text, e.g. "2.0.0" — read by installer smoke tests
```

Intentionally **not** installed: MinGW, Go, CMake, Node — none of these are runtime deps (everything is statically built).

### Registry Keys Written

All four are written by the installer, and all four are removed by the uninstaller:

```
HKLM\SOFTWARE\Clients\Mail\go-mapi
    (Default)                           = "go-mapi (Gmail bridge)"
    DLLPath                             = "C:\Program Files\go-mapi\go-mapi.dll"
    # MAPI handler registration — same as install.ps1 does today.

HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host
    (Default)                           = "C:\Program Files\go-mapi\manifests\com.gomapi.host.chrome.json"

HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host
    (Default)                           = "C:\Program Files\go-mapi\manifests\com.gomapi.host.edge.json"

HKLM\SOFTWARE\Clients\Mail                             # backup only, not our main key
    (Default, before install)  ──▶  uninst\previous-mail-client.json
    (Default, after install)   = "go-mapi"             # optionally — gated by a checkbox "set as default"
```

Notes:

- **Chromium.** Chrome picks up Chromium-fork extensions via Chrome's key in practice (tested in `install.ps1` today). We do not write a separate Chromium key in v2.0.0.
- **Manifest `allowed_origins`.** Both rendered manifests must include the *production* Chrome Web Store extension ID and the *Edge Add-ons* extension ID. These go into the `.tmpl` files as comma-separated build-time constants because the published extension IDs are stable; no runtime detection needed.
- **Per-user fallback.** If a future milestone needs a non-admin install path, switch `PrivilegesRequired=lowest`, use `HKCU\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host`, and accept that the MAPI registration stops working (HKLM-only). Out of scope for v2.0.0 — documented here so future work doesn't have to re-research it.

### Uninstall Data File

`C:\Program Files\go-mapi\uninst\previous-mail-client.json`:

```json
{
  "version": 1,
  "captured_at": "2026-04-11T10:12:34Z",
  "previous_default_mail_client": "Mozilla Thunderbird"
}
```

- Captured by the installer's `[Code]` section **before** any registry write, by reading `HKLM\SOFTWARE\Clients\Mail\(Default)`.
- Consumed by the uninstaller to restore the previous value. If the file is missing or the captured client no longer exists, the uninstaller clears `HKLM\SOFTWARE\Clients\Mail\(Default)` rather than leaving go-mapi dangling.
- Kept in `uninst\` (not next to the binaries) so a manual `del` of the app directory doesn't accidentally take the backup with it.

### What the Installer Does Not Do

- **Does not install Chrome / Edge.** Hard requirement; checked at install time. If neither is detected, show a warning but allow the install to proceed (user might install a browser later).
- **Does not install the extension.** The user installs the extension from the Chrome Web Store / Edge Add-ons. The installer shows the two store URLs on the final wizard page.
- **Does not auto-update itself.** Deferred per `PROJECT.md` key decisions. The installer knows its own version (`{#MyAppVersion}` constant) and writes `C:\Program Files\go-mapi\VERSION` — that's the whole update mechanism for v2.0.0.
- **Does not sign itself.** Signing is a post-build step driven by CI (SignPath.io integration if it lands, raw `.exe` otherwise). The installer script doesn't know or care whether the binary it produced will be signed.

---

## 4. Extension Host-Detection State Machine

The *existing* service worker already calls `chrome.runtime.connectNative('com.gomapi.host')`, attaches an `onDisconnect` listener, and reads `chrome.runtime.lastError` (see `src/extension/src/background/service-worker.ts` lines 66-74 and 105). **We do not rebuild that** — we extract it into `hostDetector.ts` and add classification + version comparison.

### States

```
                    ┌─────────┐
                    │ UNKNOWN │  (service worker just loaded, never tried)
                    └────┬────┘
                         │ connectNative()
                         ▼
                    ┌─────────┐
                    │ PROBING │
                    └────┬────┘
          ┌──────────────┼──────────────────┬────────────────┐
          │              │                  │                │
          │ onDisconnect │ READY received   │ READY received │ onDisconnect
          │ lastError    │ version >= MIN   │ version < MIN  │ lastError
          │ matches      │                  │                │ OTHER
          │ "not found"  │                  │                │
          ▼              ▼                  ▼                ▼
     ┌─────────┐    ┌────────┐        ┌──────────┐     ┌────────┐
     │ MISSING │    │ READY  │        │ OUTDATED │     │ ERROR  │
     └────┬────┘    └────┬───┘        └────┬─────┘     └───┬────┘
          │              │                 │               │
          │ retry alarm  │ (queue flows    │ retry alarm   │ retry with
          │ every 30s    │  work normally) │ every 30s     │ existing 6s
          │ after user   │                 │ after user    │ reconnect
          │ clicks       │                 │ clicks        │ backoff
          │ "Install"    │                 │ "Update"      │
          └──────────────┴─────────────────┴───────────────┘
```

### Disconnect-Error Classification

`chrome.runtime.lastError.message` strings (from Chrome's source; verified against the Chrome developer docs):

| lastError pattern | Classification | New state |
|---|---|---|
| `"Specified native messaging host not found."` | Manifest missing (host not installed) | `MISSING` |
| `"Native host has exited."` followed immediately by reconnect failing the same way | Host binary exited before sending `READY` — probably crashed; treat as transient | `ERROR`, existing 6s backoff applies |
| `"Access to the specified native messaging host is forbidden."` | Extension ID not in `allowed_origins` (installer shipped wrong ID, or user side-loaded a dev build) | `ERROR` with specific dev-mode hint |
| anything else, or no `lastError` but disconnect before `READY` | Unknown transport error | `ERROR`, existing 6s backoff |

Only the first case triggers the `InstallPrompt` UI — the others are not install problems and should not show an "install now" button.

### Version Comparison

The host already sends `READY` with its version string (`src/native-host/protocol.go` line 171-174, `SendReady(version)`). We need:

- **`MIN_SUPPORTED_HOST_VERSION`** in `src/extension/src/lib/hostVersion.ts`, a build-time constant the extension ships with.
- **A semver compare** — trivial, three-integer split; no dep needed. The existing versions are `"1.0.0"` style so a 5-line comparator suffices.
- **`READY.version < MIN`** transitions to `OUTDATED`, not `ERROR`. `OUTDATED` shows the same prompt as `MISSING` with different copy ("A newer version of the go-mapi host is needed" / "Download update").

### What Goes in the Service Worker vs `hostDetector.ts`

- **`hostDetector.ts`** exports a single class with: a `state: HostState`, a `start()` / `stop()` pair, a `probe()` method, and an `onChange(listener)` subscription. It owns the `chrome.runtime.Port`. It does not know about React, notifications, the queue, or alarms.
- **`service-worker.ts`** instantiates one `HostDetector`, subscribes to state changes, and plugs those into the existing systems: on `READY` → connect the message pump (existing code); on `MISSING`/`OUTDATED` → set a badge ("!"), broadcast a `QUEUE_UPDATE`-style message to the popup so it shows the InstallPrompt; on the `MISSING → READY` transition → fire `chrome.notifications.create()` (the success toast) and clear the badge.

This keeps the existing service worker's "connection hub" role intact and makes `hostDetector.ts` unit-testable with the existing `src/extension/src/test/mocks/chrome.ts`.

---

## 5. Data Flow: Install From Extension (End-to-End)

```
(1) User opens extension popup
     │
     ▼
(2) Popup renders, calls chrome.runtime.sendMessage({action:'getHostState'})
     │
     ▼
(3) Service worker reads hostDetector.state
     │     (on cold start: service worker calls hostDetector.start()
     │      which calls connectNative() and transitions UNKNOWN → PROBING)
     │
     ▼
(4) hostDetector receives onDisconnect with
     lastError.message === "Specified native messaging host not found."
     │
     ▼
(5) hostDetector transitions PROBING → MISSING, fires onChange
     │
     ▼
(6) Service worker broadcasts {type:'HOST_STATE', state:'MISSING'} to popup
     │     Service worker also sets chrome.action.setBadgeText('!')
     │     Service worker schedules retry alarm for 30s
     │
     ▼
(7) Popup receives HOST_STATE, renders <InstallPrompt/> instead of <EmailList/>
     │     "The go-mapi companion app is not installed.
     │      [Install now] [Already installed? Retry]"
     │
     ▼
(8) User clicks "Install now"
     │
     ▼
(9) Popup calls chrome.tabs.create({url: INSTALLER_URL})
     │     INSTALLER_URL = "https://go-mapi.marcfargas.com/download/latest.exe"
     │     (or a permanent GitHub release-assets URL if stable-URL hosting lands later)
     │     The popup stays open; the browser navigates a new tab to the download.
     │
     ▼
(10) Browser downloads go-mapi-setup-X.Y.Z.exe
     │
     ▼
(11) User runs the .exe, clicks through UAC, clicks Next, Next, Install
     │
     ▼
(12) Installer writes:
     │     - Files to C:\Program Files\go-mapi\
     │     - 3 native-messaging + 1 MAPI registry key family
     │     - Rendered manifests with real extension IDs
     │     - previous-mail-client.json for uninstall
     │
     ▼
(13) Meanwhile, the extension's 30-second retry alarm (set in step 6) fires
     │     calling hostDetector.probe() which calls connectNative() again
     │
     ▼
(14) This time the manifest IS found, the Go host starts, writes READY,
     │     hostDetector transitions PROBING → READY, fires onChange
     │
     ▼
(15) Service worker sees MISSING → READY transition:
     │     - clears the action badge
     │     - fires chrome.notifications.create('host-ready',
     │         { title: 'go-mapi is ready', message: '...' })
     │     - broadcasts {type:'HOST_STATE', state:'READY'} to popup
     │
     ▼
(16) If popup is open, it receives the broadcast and re-renders <EmailList/>
     │     (which is now empty — that's fine, the user hasn't sent anything yet)
     │     If popup is closed, the notification toast is the only user-visible
     │     confirmation. That's enough — the next "Send to Mail recipient" will
     │     then surface an email normally.
```

### Key Design Points of This Flow

- **No "open Chrome: open extension popup: reload" step.** The 30-second alarm closes the gap automatically. Worst case the user clicks "Already installed? Retry" in the popup, which is a direct `hostDetector.probe()` call.
- **The popup does not need to be open when install finishes.** `chrome.notifications` fires from the service worker and the badge clears server-side. If the user watched the installer complete and then opened the popup, they see the queue view directly.
- **No download-progress tracking.** We do not inspect `chrome.downloads` — the browser already shows download progress; duplicating it is complexity for no gain.
- **No handshake beyond the existing `READY`.** The v1.0.0 protocol already has the right primitive: host sends `READY` with a version, extension receives or doesn't. We are *reading* that signal more carefully; we are not extending the protocol. This is deliberate — protocol changes mean host/extension version skew problems, which is exactly what we're trying to detect, not create.

---

## 6. Build-Order Dependencies

This is the critical read for roadmap sequencing — certain components must exist before others can be meaningfully tested.

### Dependency Graph

```
                       ┌──────────────────────────────┐
                       │  EXISTING v1.0.0 components  │
                       │  (DLL, Go host, extension)   │
                       └──────────────┬───────────────┘
                                      │
                 ┌────────────────────┼────────────────────┐
                 │                    │                    │
                 ▼                    ▼                    ▼
         ┌──────────────┐    ┌────────────────┐   ┌─────────────────┐
         │ hostVersion  │    │ mock-host      │   │ version.go      │
         │ .ts + MIN    │    │ (Go, stdio)    │   │ (Go constant)   │
         │ constant     │    │                │   │                 │
         └──────┬───────┘    └────────┬───────┘   └────────┬────────┘
                │                     │                    │
                ▼                     │                    │
         ┌──────────────┐             │                    │
         │ hostDetector │             │                    │
         │ .ts + unit   │             │                    │
         │ tests        │             │                    │
         └──────┬───────┘             │                    │
                │                     │                    │
                ▼                     │                    │
         ┌──────────────┐             │                    │
         │ InstallPrompt│             │                    │
         │ .tsx + unit  │             │                    │
         │ tests        │             │                    │
         └──────┬───────┘             │                    │
                │                     │                    │
                ▼                     ▼                    │
         ┌─────────────────────────────────┐               │
         │ service-worker.ts integration   │               │
         │ (host detection wired in)       │               │
         └──────────────┬──────────────────┘               │
                        │                                  │
                        │       ┌──────────────────────────┘
                        │       │
                        ▼       ▼
                ┌────────────────────────┐
                │ Playwright E2E         │
                │ "install-ux" spec      │  ── does NOT need real installer
                │ (uses mock-host)       │
                └────────────────────────┘
                        │
                        ▼
                ┌────────────────────────┐
                │ Inno Setup .iss +      │
                │ manifest templating    │
                └──────────┬─────────────┘
                           │
                           ▼
                ┌────────────────────────┐
                │ build-installer.ps1    │
                │ (orchestrates all      │
                │  three builds + ISCC)  │
                └──────────┬─────────────┘
                           │
                           ▼
                ┌────────────────────────┐
                │ Pester installer       │
                │ smoke tests            │
                └──────────┬─────────────┘
                           │
                           ▼
                ┌────────────────────────┐
                │ CI: installer.yml      │
                │ + signed artifact      │
                └────────────────────────┘
```

### Ordering Consequences For The Roadmap

1. **hostVersion constant + version.go come first.** Both are two-line changes with no dependencies. Everything version-aware (host detection, installer version stamp, smoke tests, E2E) reads from them.
2. **Mock host can be built in parallel with hostDetector.** They share `protocol.go` types but otherwise do not touch each other.
3. **hostDetector + InstallPrompt must land before the service worker wires them in.** Service worker integration is the "big bang" step where MISSING starts surfacing to the popup — keep the units separate to make unit tests feasible.
4. **E2E "install-ux" spec does NOT need the real installer.** This is the most important build-order insight: the install-UX test can simulate "host gets installed" by having the test harness write the native-messaging manifest file and launch the mock host between two probe attempts. This decouples the extension test suite from the installer build, which would otherwise be a circular dependency (extension tests need installer, installer tests need extension to be built).
5. **Real installer can happen in parallel with E2E.** Once the templated manifests and registry layout are specified (§3 above), an Inno Setup script can be written without touching any other component.
6. **Pester smoke tests require the installer `.exe` to exist.** They must run in CI after `build-installer.ps1`.
7. **Code signing is the last step.** It takes an already-built `.exe` and produces a signed one. It does not affect any test suite's behavior. If SignPath.io falls through, shipping unsigned does not block any prior step.

### Minimum Useful Slice (for an early dogfood)

The smallest subset that is demonstrably better than v1.0.0 for a non-technical user:

1. `hostVersion.ts` + `version.go`
2. `hostDetector.ts` + unit tests
3. `InstallPrompt.tsx` with a hard-coded GitHub release URL (no custom CDN yet)
4. service-worker.ts integration
5. Inno Setup `.iss` producing an unsigned `.exe`, manually tested

Everything else (E2E, Pester, signing, `-race` in CI, TS test coverage gaps) hardens this slice but does not extend it.

---

## 7. Integration Points With Existing Code

Explicit list of *every* existing file the v2.0.0 work touches, so the roadmap can scope each phase concretely.

| Existing file | What changes | Reason |
|---|---|---|
| `src/extension/src/background/service-worker.ts` | Import and instantiate `HostDetector`; subscribe to state changes; move existing `connectNative`/`onDisconnect` logic into `HostDetector`; add `HOST_STATE` broadcast; add MISSING→READY notification trigger; keep existing 6-second reconnect alarm (used for `ERROR`, not `MISSING`). | This is where the plumbing lands. |
| `src/extension/src/popup/App.tsx` | Listen for `HOST_STATE` messages; conditionally render `<InstallPrompt/>` vs `<EmailList/>`. | Existing top-level state owner. |
| `src/extension/src/types/messages.ts` | Add `HOST_STATE` message type + `HostState` enum for popup/service-worker broadcast (internal to extension, NOT part of native messaging protocol). | Keep the existing pattern of one central message-types file. |
| `src/extension/src/test/mocks/chrome.ts` | Add `setLastErrorNotFound()` helper that sets a realistic `"Specified native messaging host not found."` string. | Needed to test the MISSING classification path in `hostDetector.test.ts`. |
| `src/native-host/main.go` | Read version from a new `Version.go` constant instead of the current `Version` literal (line 28). | Single source of truth for installer, CI, and `READY` payloads. |
| `src/native-host/protocol.go` | No change — `SendReady(version)` already exists. | This is why the handshake does not need protocol changes. |
| `src/native-host/manifests/com.gomapi.host.chrome.json` | Renamed to `.tmpl`; adjusted to use a `{{HOST_PATH}}` and `{{EXTENSION_ID}}` placeholder Inno Setup will substitute (instead of `EXTENSION_ID_PLACEHOLDER`). | Single templating scheme across installer and any future developer install script. |
| `src/native-host/manifests/com.gomapi.host.edge.json` | Same as above. | Same reason. |
| `scripts/install.ps1` | **Keep** as the developer path; add a banner at top: "This is the developer install. End users should run go-mapi-setup-X.Y.Z.exe instead." Update its manifest-writing code to consume the new `.tmpl` files so there is only one template spec. | Developer workflow still matters; don't fragment manifest rendering into two divergent implementations. |
| `package.json` (root) | Add scripts: `build:installer`, `test:e2e`, `test:installer`, `test:race` (Go race). | Discoverable commands; CI calls them directly. |
| `tests/e2e/playwright.config.ts` | Currently an empty shell; populate with project config, globalSetup for mock host launch. | The file already exists waiting to be filled. |
| `.github/workflows/ci.yml` | Add `go test -race ./...` job; add `npm run test` in `src/extension`; keep existing DLL + Go + extension build jobs. | Existing CI skeleton stays intact. |
| `.github/workflows/installer.yml` (new) | Runs `build-installer.ps1`, then `Invoke-Pester tests/installer/`. Uploads artifact. | Kept separate from `ci.yml` so PRs that don't touch the installer don't pay the cost. |
| `.github/workflows/e2e.yml` (new) | Builds extension, builds mock host, runs Playwright. Windows runner. Uploads traces on failure. | Same separation rationale. |

### Files *not* touched

- `src/interceptor/**` — the DLL is unchanged for v2.0.0. (Adding DLL tests is in `TESTING.md` gaps but not an architecture question; they go under the existing `test-harness/`.)
- `src/native-host/watcher.go`, `gmail.go` — unchanged for the install UX work; gmail.go gets touched only when filling the `buildFullMIME` test gap, which is a test-only change.
- `src/extension/src/lib/gmail.ts` — the Chrome Identity wrapper stays as-is.
- `src/extension/public/manifest.json` — no new permissions needed. `nativeMessaging`, `notifications`, `tabs`, `alarms`, `storage` are presumably already declared (verify during implementation). If `tabs` is missing, add it; opening the installer download URL uses `chrome.tabs.create`.

---

## 8. E2E Test Architecture

### Core Insight: We Already Have Filesystem IPC

The single most important fact about testing this project end-to-end: **the DLL communicates with the Go host via the filesystem, not shared memory or COM.** This means an E2E test can skip the DLL entirely and simulate "the user sent an email" by writing a JSON file into `%TEMP%\go-mapi\`. This is the whole reason a fast, deterministic E2E suite is feasible for a project that otherwise involves loading a DLL into another process's address space.

### Three Tiers of "E2E"

| Tier | What runs | What's mocked | What's real | Speed | Location |
|---|---|---|---|---|---|
| **T1: File-drop happy path** | Extension (loaded into real Chromium via Playwright) + real `go-mapi-host.exe` | DLL (not called); Gmail API (intercepted via Playwright's request routing) | Service worker, popup, fsnotify watcher, native messaging protocol | ~5s | `tests/e2e/specs/happy-path.spec.ts` |
| **T2: Install-UX spec** | Extension loaded into Chromium; mock host binary | Real Go host (the test *wants* it absent at start); Gmail API; DLL | hostDetector, InstallPrompt, service-worker state transitions | ~10s | `tests/e2e/specs/install-ux.spec.ts` |
| **T3: Installer smoke** | Real `go-mapi-setup-X.Y.Z.exe` in a sandbox install dir | Everything above | The installer binary, registry writes, file layout, uninstall | ~30s | `tests/installer/install.smoke.Tests.ps1` (Pester, not Playwright) |

No single test exercises all three tiers — that would require actually running a Windows app that calls `MAPISendMail`, which is both slow and flaky. The three tiers together cover every line from MAPI capture to Gmail draft without ever needing to do so.

### T1 "Happy Path" Mechanics

1. Playwright `chromium.launchPersistentContext(userDataDir, { args: ['--load-extension=src/extension/dist', ...] })`.
2. Global setup writes a native-messaging manifest into `userDataDir/NativeMessagingHosts/com.gomapi.host.json` pointing at the *real* `go-mapi-host.exe` built from `src/native-host/`, with `allowed_origins` set to the test extension ID (retrieved from the service worker URL, per Playwright's documented pattern).
3. Global setup sets `GOMAPI_WATCH_DIR` env var (new — trivial addition to `main.go`) so the host watches a per-test temp dir instead of `%TEMP%\go-mapi\`. This is the only new affordance the host needs for testability.
4. The test uses `page.route()` to intercept `https://gmail.googleapis.com/gmail/v1/users/me/drafts` and return a canned success response. No real Gmail token needed.
5. The test drops `tests/e2e/fixtures/simple-email.json` into the watched temp dir.
6. The test opens the extension popup via the service-worker URL trick, asserts the email appears in the list, clicks "Save as Draft", asserts the intercepted Gmail route was hit, asserts the notification fired.

### T2 "Install UX" Mechanics

1. Same extension launch, but global setup does NOT write the native-messaging manifest.
2. Test opens the popup, asserts the `<InstallPrompt/>` is visible.
3. Test simulates "user installed the app" by writing the manifest pointing at the mock host (`tests/e2e/mock-host/`) with scenario `happy-path.json`.
4. Test fires the popup's "Already installed? Retry" button (cheaper than waiting for the 30s alarm in a test).
5. Test asserts state becomes READY, success notification fired, popup transitions to `<EmailList/>`.
6. Also test the `OUTDATED` path by pointing at the mock host in a scenario that reports `version: "0.1.0"`.

### Mock Host Rationale

- **Why a separate Go binary and not a JS test double?** Chrome's native messaging requires a real child process with stdin/stdout framing. There is no hook to inject a JS-level mock into `chrome.runtime.connectNative`.
- **Why Go?** Shares protocol types directly with `src/native-host/protocol.go`. About 100-150 LOC.
- **Why not use the real host?** For T2 we want scripted scenarios (e.g. "start up and immediately exit with code 1", "send READY with old version"). The real host doesn't offer those knobs and shouldn't — scripted failure modes are test-only.
- **Scenario file over CLI flags** because Windows path quoting in native-messaging manifest `path` is already fragile. Scenario file path goes in a `GOMAPI_MOCK_SCENARIO` env var that the Go binary reads at startup.

### Go Module Layout for the Mock Host

Two options, both acceptable:

- **Option A** (recommended): single root `go.mod`, mock host lives at `tests/e2e/mock-host/` and imports `github.com/marcfargas/go-mapi/src/native-host` for types. Simpler; everything builds with one `go build ./...`.
- **Option B**: separate `go.mod` at `tests/e2e/mock-host/` with a local `replace` directive. Useful if the test code must not leak into the shipped host binary's dependency graph, but v2.0.0 has no such concern.

Go with Option A unless someone has a hard reason otherwise during implementation.

### What About Service Worker Suspension?

Chrome MV3 service workers suspend after ~30 seconds of inactivity. The existing codebase already uses `chrome.alarms` to survive this (see reconnect logic in `service-worker.ts`). For E2E tests, we follow the community pattern: assert **outcomes** (`chrome.storage.session` contents, visible notifications, DOM state) rather than introspecting the service-worker's in-memory `emails` Map directly. The existing mocked `chrome.storage.session` pattern in `src/extension/src/test/mocks/chrome.ts` already assumes this shape.

---

## 9. CI Test Matrix

Running on GitHub Actions `windows-latest` (GitHub-hosted runner, which has MinGW, MSBuild, Go, Node, Inno Setup via Chocolatey, Chrome preinstalled).

| Workflow | Triggers | Jobs | Duration (target) |
|---|---|---|---|
| `ci.yml` | every PR, every push to `develop`/`main` | (a) Go unit+integration tests, (b) Go `-race` tests (same code, separate job for isolated failure reporting), (c) C++ DLL build + `test-harness` run, (d) TS lint + `vitest run --coverage` for extension, (e) Full build of all three components (the existing build matrix) | ≤ 8 min |
| `installer.yml` | PRs that touch `src/installer/**`, `src/native-host/manifests/**`, `scripts/build-installer.ps1`, or weekly cron | (a) Build DLL + host + extension (reuses `ci.yml` artifacts via `actions/download-artifact`), (b) Choco-install Inno Setup, (c) Run `build-installer.ps1`, (d) `Invoke-Pester tests/installer/`, (e) Upload signed or unsigned `.exe` as artifact | ≤ 10 min |
| `e2e.yml` | PRs that touch `src/extension/**`, `src/native-host/**`, or `tests/e2e/**` | (a) Build host + extension, (b) Build mock host, (c) `npx playwright install chromium`, (d) Run `npm run test:e2e`, (e) Upload trace on failure | ≤ 12 min |
| `release.yml` (existing, if present) | git tag `v*` | Build signed installer, attach to GitHub release, publish extension zip | — |

### Why Split Into Three Workflows

- **`ci.yml` is the fast lane.** It must stay under 10 minutes or people stop paying attention to it. Everything in `ci.yml` runs on every PR.
- **`installer.yml` is the slow lane.** Building the installer requires Inno Setup to be present and Pester smoke tests to elevate; both are costly. Gate on path filters so the 95% of PRs that don't touch the installer don't wait for it.
- **`e2e.yml` is a second slow lane** because Playwright downloads Chromium on first run and the tests themselves are slower than unit tests. Same path-filter treatment.

### The `-race` Job

Current state: no `-race` anywhere. Needed because the watcher (`watcher.go`) uses goroutines for fsnotify events and debouncing. New job:

```yaml
- name: Go tests with race detector
  working-directory: src/native-host
  run: go test -race -count=1 ./...
```

Separate from the normal `go test` job so (a) normal test failures and race failures are distinguishable in the CI UI, (b) flaky race detection doesn't hide real unit test failures.

### Concurrency

Use `concurrency: group: ${{ github.workflow }}-${{ github.ref }}, cancel-in-progress: true` on all three workflows so a quick second push cancels the first run. Saves runner minutes on iterative PRs.

---

## 10. Anti-Patterns To Avoid

### AP1: Extending the native-messaging protocol for "install status"

**What people do:** Add a new `HOST_CAPABILITIES` message type to the native messaging protocol so the extension can ask the host "do you support install auto-update?"

**Why it's wrong:** The host and extension are version-skewed by design — the user installs them separately. A new protocol message only exists in *newer* hosts, so the extension can never assume it's there without first doing the exact `READY`-or-not detection we're already doing. The new message adds complexity without solving anything.

**Do this instead:** Reuse the existing `READY` + `version` string. Make the extension smarter about classifying the absence of `READY`. This is what §4 describes.

### AP2: Writing the installer in Go ("one language for everything")

**What people do:** Skip Inno Setup, write a Go program that copies files, writes registry keys, and prompts for UAC via ShellExecute.

**Why it's wrong:** You end up reimplementing (badly): UAC elevation, wizard UI, license acceptance, uninstall registration in `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`, Windows SmartScreen reputation flow, Add/Remove Programs integration, upgrade-in-place detection. Inno Setup has all of this, battle-tested for 25 years. A solo FOSS maintainer writing it from scratch is a multi-month project with no differentiated value.

**Do this instead:** Inno Setup 6, Pascal `[Code]` block for the few custom bits (manifest templating, previous-mail-client backup).

### AP3: "Polling `connectNative` every N seconds" as the detection strategy

**What people do:** After the popup opens, set a `setInterval(() => { chrome.runtime.connectNative(...) }, 5000)` and check if it works.

**Why it's wrong:** Each `connectNative` attempt *spawns the host process* if the manifest exists. You end up launching and killing `go-mapi-host.exe` every 5 seconds, thrashing fsnotify, log files, and potentially races on the watch directory. Also service worker suspension kills the interval silently.

**Do this instead:** Single probe on service-worker startup (§4 state machine). Retry via `chrome.alarms` which is suspension-safe, and only when in `MISSING`/`OUTDATED` state. In `READY`, do nothing — the existing `onDisconnect` handler already catches a crash and reconnects.

### AP4: Putting install-prompt logic inside the popup's `App.tsx`

**What people do:** Add an `if (!hostConnected)` branch at the top of `App.tsx` that reaches into `chrome.runtime` directly.

**Why it's wrong:** The popup is a short-lived view; it mounts and unmounts every time the user opens or closes it. State lives in the service worker, not in React. Putting connection logic in the popup means the detection restarts every popup open, the install prompt flickers on slow probes, and tests have to mount React components to test connection logic.

**Do this instead:** Detection lives in the service worker via `hostDetector.ts`. Popup subscribes to a broadcast and renders passively. The popup contains *zero* native-messaging logic.

### AP5: Using `chrome.downloads` to watch the installer download

**What people do:** Request the `downloads` permission, monitor the installer's download, show a progress bar in the popup, auto-launch when complete.

**Why it's wrong:** Adds a scary new permission prompt in the Chrome Web Store review ("this extension wants to access your downloads"), which is the opposite of what a v2.0.0 targeted at non-technical users wants. Auto-launching downloaded `.exe` files from an extension is the shape of a malware distribution flow and gets flagged by Chrome Web Store review.

**Do this instead:** `chrome.tabs.create(installerUrl)`. The browser handles the download with its own UI and security UX. The extension just waits for the 30s alarm + `MISSING → READY` transition to confirm install completed.

### AP6: Testing the installer by running it against `C:\Program Files\go-mapi\` on the CI runner

**What people do:** Pester smoke test installs to the default install dir, inspects it, uninstalls.

**Why it's wrong:** Contaminates the runner's real MAPI handler registration, fights with anti-virus software on any runner that has AV active, and makes parallel runs impossible.

**Do this instead:** Pester test passes `/DIR="$env:TEMP\go-mapi-smoke-$(Get-Random)"` to the Inno Setup installer, verifies registry writes under a per-test key (Inno Setup supports an `AppId` + a `HKLM\...\$AppId` scoped root via the `[Setup]` `AppId` directive) or under a per-test `AppId` suffix, and cleans up at the end via `Pester`'s `AfterAll`. The smoke test verifies that the installer *can* write the right keys, not that it overwrites the real machine state.

---

## 11. Scaling Considerations (lightweight — this is a desktop tool)

This is a solo-maintainer desktop productivity tool. Scaling is not about users/second; it is about **fanout of machines the installer must work on** and **long-tail edge cases it must survive**.

| Scale | What to worry about |
|---|---|
| 1-10 users (Marc + friends) | The installer runs on one Windows version, signed or not. |
| 10-100 users | Windows 10 vs 11 differences in `%TEMP%` handling, per-user vs per-machine install collisions if a user re-installs on top of an old PowerShell install, anti-virus false-positives on unsigned binaries. |
| 100-1000 users | SmartScreen reputation issues on unsigned binaries become the top support burden — prioritize getting a signature. Enterprise-locked machines that forbid writing under `HKLM`. Non-English Windows locales breaking installer path logic. |
| 1000+ users | Auto-update starts being cheaper than answering "how do I upgrade" questions. But this is explicitly deferred per `PROJECT.md`. |

**What breaks first** at the 10-100 scale: unsigned-binary warnings and re-install-on-top collisions. Both are tractable — the first via code signing, the second via Inno Setup's built-in `AppId`-based upgrade detection (it handles "upgrade in place" natively when the `AppId` matches).

---

## 12. Open Questions For Implementation

These are things this research deliberately does not answer because they need decisions at implementation time rather than more research:

1. **Stable download URL.** PROJECT.md says "Extension links directly to installer download (not a GitHub release page)". Options: (a) host `go-mapi-setup-latest.exe` at a fixed path in a GitHub Pages site under `marcfargas.github.io/go-mapi/`, (b) use the Cloudflare + Traefik infra on `*.blegal.dev`, (c) use GitHub release assets with a redirecting landing page. This is a hosting question, not an architecture question — leave for phase planning.
2. **SignPath.io enrollment timeline.** If they approve the project, installer is signed. If they decline or take too long, ship unsigned with a SmartScreen explainer page at `/install`. Either way the installer build does not change; only the post-build step and the download landing page change.
3. **`MIN_SUPPORTED_HOST_VERSION` for v2.0.0.** Probably `"1.0.0"` (every shipped host so far qualifies), so `OUTDATED` is a dead branch in the v2.0.0 state machine. That's fine — landing the branch early means v3.0.0 can bump the constant and the UX is already there. Decision: ship the code path, set the constant to the current host version (whatever ends up in `version.go`).
4. **Extension store listing IDs for `allowed_origins`.** Need both Chrome Web Store ID and Edge Add-ons ID hard-coded into the manifest templates. These are known from the existing v1.0.0 shipment but need to be explicitly referenced in `src/installer/`.

---

## Sources

- [Chrome Native Messaging official docs](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) — authoritative on manifest registry locations (HKLM vs HKCU), the `connectNative` error flow, `allowed_origins` rules. HIGH.
- [Microsoft Edge Native Messaging docs](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/native-messaging) — Edge registry path (`HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\`). HIGH.
- [Inno Setup `[Registry]` section reference](https://jrsoftware.org/ishelp/topic_registrysection.htm) — HKLM/HKCU syntax, uninstall behavior, elevation. HIGH.
- [Eric Lawrence, Web-to-App Communication: The Native Messaging API](https://textslashplain.com/2020/09/04/web-to-app-communication-the-native-messaging-api/) — practical notes on Chrome-vs-Edge and per-user vs per-machine trade-offs. MEDIUM (blog post, but by an MS Edge engineer).
- [Playwright Chrome Extensions docs](https://playwright.dev/docs/chrome-extensions) — persistent-context launch pattern, service worker retrieval. HIGH.
- [How I Built E2E Tests for Chrome Extensions Using Playwright and CDP (dev.to, 2026)](https://dev.to/corrupt952/how-i-built-e2e-tests-for-chrome-extensions-using-playwright-and-cdp-11fl) — recent pattern for MV3 service-worker assertion strategies. MEDIUM.
- [Capital BR, chrome-extension-for-testing (GitHub)](https://github.com/capitalbr/chrome-extension-for-testing) — template MV3 + Playwright repo; useful as a layout reference. MEDIUM.
- Existing `.planning/codebase/ARCHITECTURE.md`, `STRUCTURE.md`, `INTEGRATIONS.md` — single source of truth for the v1.0.0 baseline that these v2.0.0 components attach to. HIGH.
- Direct source reads: `src/native-host/protocol.go` (`MsgTypeReady`, `SendReady(version)`), `src/extension/src/background/service-worker.ts` (existing `connectNative` + `onDisconnect` flow), `src/native-host/manifests/com.gomapi.host.chrome.json` (current template shape), `scripts/install.ps1` (current registration semantics). HIGH.

---

*Architecture research for: go-mapi v2.0.0 installer + extension handshake + test infrastructure*
*Researched: 2026-04-10*
