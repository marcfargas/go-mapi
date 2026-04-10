# Pitfalls Research — go-mapi v2.0.0

**Domain:** Windows installer + Chrome/Edge native messaging handshake + test completeness for a mixed Go/TS/C++ project
**Researched:** 2026-04-10
**Confidence:** HIGH (most pitfalls verified against official docs, bug trackers, and community post-mortems; confidence notes called out per-pitfall where sources are weaker)

> **Scope note:** These pitfalls are specific to the v2.0.0 workstreams — **not** the already-shipped v1.0.0 bridge. Existing codebase concerns (race in `emails` map, stale attachment paths, missing HTTP timeout, etc.) are tracked in `.planning/codebase/CONCERNS.md` and are referenced here only when a v2.0.0 workstream would expose or aggravate them.

---

## Critical Pitfalls

### Workstream 1: Installer Technology (Inno Setup / WiX)

#### Pitfall 1.1: UAC elevation swaps user context, breaking HKCU and `%USERPROFILE%` writes

**What goes wrong:**
The installer runs elevated (required to write `HKLM\SOFTWARE\Clients\Mail\go-mapi` and drop the DLL in Program Files). Once elevated, `{userappdata}`, `{userpf}`, `{localappdata}` and `HKCU` in Inno Setup resolve to the **Administrator's** profile — not the profile of the user who double-clicked the installer. If the native messaging manifest is written under HKCU (which Chrome allows), it ends up in the wrong hive and Chrome reports "Specified native messaging host not found" for the actual user.

**Why it happens:**
Windows UAC invents a new logon session for the elevated process. Inno Setup's `PrivilegesRequired=admin` swaps all per-user constants to the elevating account. Developers test on single-user dev boxes where this aliasing is invisible.

**Concrete example:**
Rubberduck-VBA installer (Inno Setup): installed add-ins to the Administrator's HKCU instead of the invoking user's. Issue #458 documents multi-page debugging before the team discovered the context swap. Same class of bug hit `browserpass-native` when registering Chromium-based browser manifests.

**How to avoid:**
- Prefer **HKLM** for the native messaging manifest registry key (Chrome supports both `HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host` and `HKCU\...`; HKLM works machine-wide and is immune to context swapping).
- Write the manifest file under `%ProgramData%\go-mapi\` (machine-wide, survives profile roaming), **not** `%LOCALAPPDATA%`.
- Use `PrivilegesRequired=admin` + `PrivilegesRequiredOverridesAllowed=dialog commandline` so users can downgrade if they want a per-user install.
- If a per-user mode is ever added later: use Inno Setup's `runasoriginaluser` flag in `[Run]` sections and `ExpandConstant('{%USERNAME}')` to recover the real user.
- **Test on a VM with a separate non-admin user** before shipping — bug is invisible on single-user dev boxes.

**Warning signs:**
- Beta tester reports "Chrome says host not found even though installer said success"
- `regedit` shows the manifest key under `HKU\S-1-5-21-...-500` (Administrator SID) instead of the user's SID
- Manifest file exists at `C:\Users\Administrator\AppData\...` when user account is `Alice`

**Phase to address:** Installer phase (before first beta). Integration test = install on VM as user "Alice", check `HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host` exists and points to a path readable by Alice.

---

#### Pitfall 1.2: Inno Setup single-EXE ships without a working uninstaller entry for MAPI handler

**What goes wrong:**
Uninstall removes files and the native messaging registry keys but forgets to remove `HKLM\SOFTWARE\Clients\Mail\go-mapi` (the MAPI handler registration). After uninstall, Windows still lists go-mapi as an available mail client in Default Apps, and any app that calls `MAPISendMail()` into the stale registration will either silently fail or crash because the DLL is gone.

**Why it happens:**
The MAPI handler registration lives under `HKLM\SOFTWARE\Clients\Mail\<handler>` — a non-obvious location outside the app's own uninstall tree. Installer authors focus on `HKLM\SOFTWARE\go-mapi` or `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi` and forget there are **five** registry trees to clean:
1. `HKLM\SOFTWARE\Clients\Mail\go-mapi` (MAPI handler)
2. `HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host`
3. `HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host`
4. `HKLM\SOFTWARE\go-mapi` (app config, if any)
5. `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi` (Add/Remove Programs entry — Inno auto-creates this)

Plus file-system cleanup for `%TEMP%\go-mapi\` leftover from v1.0.0 installs.

**How to avoid:**
- In Inno Setup `[Registry]` section, use `uninsdeletekey` flag on **every** registry entry written, including the MAPI handler tree.
- Add an `[UninstallDelete]` entry for `{commonappdata}\go-mapi\*` and `{%TEMP}\go-mapi\*` (with `Type: filesandordirs`).
- Write a CMD/PowerShell "clean uninstall verifier" that runs `reg query` on all five paths after uninstall and fails if any remain — run this in CI.
- On uninstall, actively **unregister the DLL from the MAPI client list** by deleting the `HKLM\SOFTWARE\Clients\Mail\go-mapi` subtree, not just individual values.

**Warning signs:**
- After uninstall, Default Apps → Email still shows go-mapi
- `reg query HKLM\SOFTWARE\Clients\Mail` shows a ghost `go-mapi` entry with a path pointing at a deleted DLL
- Reinstall creates a second "go-mapi" entry instead of updating the existing one
- Windows Event Log: "mapi32.dll: handler not found" warnings after an app tries to Send to Mail

**Phase to address:** Installer phase. CI smoke test = fresh VM → install → uninstall → assert all five registry trees are empty and `%ProgramData%\go-mapi` is gone.

---

#### Pitfall 1.3: DLL is in-use at uninstall time, leaving orphaned files and triggering "restart to complete"

**What goes wrong:**
Because `mapi32.dll` (or the shim that redirects to `go-mapi.dll`) is loaded into every process that imports MAPI — including Explorer shell extensions, Outlook-free Office shims, and long-running apps like Sumatra PDF — the DLL file handle is held open at uninstall time. Inno Setup tries to delete it, fails, and schedules a `PendingFileRenameOperations` for next reboot. User thinks uninstall worked but the DLL is still loaded and still intercepting until reboot. Worse: if the user reinstalls before rebooting, two DLL copies coexist and Chrome native messaging gets routed to whichever was loaded first.

**Why it happens:**
MAPI handler DLLs are designed to be loaded by arbitrary callers via `LoadLibrary`. There's no "close all handles" API. The installer has no clean way to force unload.

**How to avoid:**
- Use Inno Setup's `CloseApplications=force` + `RestartApplications=yes` directives to close known MAPI-consuming apps before replacing the DLL.
- Detect in-use state with Inno's `FileExists`/`IsModuleLoaded` scripting (`[Code]` section using `CheckForMutexes` or a custom Pascal function calling `GetModuleHandle`).
- If detected, show a clear dialog: "go-mapi is currently in use by the following applications: [list]. Please close them and click Retry, or allow the installer to close them now."
- On uninstall, if the DLL is locked, **refuse to schedule a delayed delete** — instead, show a reboot-required dialog and a "you can manually delete %s after reboot" fallback. Delayed deletes silently break upgrade paths.

**Warning signs:**
- Beta tester reports "I installed v2.0.1 over v2.0.0 and nothing changed"
- Uninstall dialog shows "Some files couldn't be removed and will be deleted on next restart"
- `handle.exe` (Sysinternals) shows the DLL handle held by `explorer.exe` or a long-running process

**Phase to address:** Installer phase. Document the known-locked scenario in the install README. Add a diagnostic command `go-mapi doctor` (or similar) that lists which processes have the DLL loaded.

---

### Workstream 2: Code Signing / SmartScreen

#### Pitfall 2.1: Shipping unsigned, expecting users to click "More info → Run anyway"

**What goes wrong:**
First-time downloaders see the red SmartScreen dialog "Windows protected your PC — Microsoft Defender SmartScreen prevented an unrecognized app from starting." The default button is "Don't run." Non-technical users interpret this as "this is a virus" and never find the tiny "More info" link that exposes the "Run anyway" button. Conversion from download → installed → working host collapses.

**Why it happens:**
SmartScreen is not just a signing check — it's a **reputation system**. Unsigned binaries start at zero reputation. Signed-with-OV-cert binaries also start near zero (unlike EV certs, which bootstrap reputation immediately). Reputation is built by download volume and user "Run anyway" clicks, which is a chicken-and-egg problem for new projects.

**Concrete example:**
Gravitational Teleport's Connect installer (GitHub issue #15995): users were blocked by SmartScreen for months despite being a well-known infrastructure company. WSLtty (issue #32) documented the same pain — the maintainer only resolved it by getting sponsorship for an EV cert. Treeverse/DVC (#5192) shipped unsigned and received steady "is this malware?" issues for over a year.

**How to avoid:**
- **Primary plan:** apply to SignPath Foundation's free OSS program. Requirements: OSI-approved license (LGPL-3.0 qualifies), actively maintained, released form to be signed, no proprietary components, verifiable reproducible build, manual approval per release. Application lead time is typically weeks, not days — **start the application in the installer phase, not the release phase**.
- **Secondary plan:** Azure Trusted Signing (rebranded "Artifact Signing") — now open to individual developers in US/Canada only as of Nov 2024. **Not available for EU individuals** at time of writing. Low monthly cost (~$10/month) if available.
- **Fallback plan:** ship unsigned with a clear "First install" guide that screenshots the exact SmartScreen dialog and circles the "More info" link. Host the guide at the download URL, not a separate docs page.
- Build reputation by asking the first 20-50 beta users to "Run anyway" — each click contributes to SmartScreen reputation telemetry.
- Do **not** buy a cheap OV cert from a random reseller expecting SmartScreen to bypass — OV-signed unknown-publisher still triggers the warning; the cert only prevents the "Unknown publisher" label on the UAC prompt.

**Warning signs:**
- Analytics on the download URL show a large gap between "download started" and "host connected" (many drop-offs)
- Beta users say "I downloaded but got scared by a red screen"
- Google search results include posts saying "is go-mapi safe? Windows flagged it"

**Phase to address:** Installer phase **and** pre-release phase. SignPath application is the long pole — if it's not approved in time for v2.0.0, fall back to unsigned + docs.

**Sources:** SignPath Foundation terms, Azure Trusted Signing FAQ, DigiCert SmartScreen reputation blog, Teleport issue #15995.

---

#### Pitfall 2.2: SmartScreen flags the binary as malware because it patches a mail API

**What goes wrong:**
go-mapi's core behavior — intercepting `MAPISendMail()` and hooking into the HKLM Mail Clients tree — matches several heuristic signatures for mail-stealer malware. Microsoft Defender and third-party AVs (especially heuristic engines like BitDefender and ESET) may quarantine the DLL or installer on download, even when signed. Reports start appearing on VirusTotal as "HEUR/Suspicious.MAPI" from 2-3 engines. Users see a false positive and distrust the project.

**Why it happens:**
Real mail-hijacking malware does exactly what go-mapi does: writes HKLM Mail Client registry, ships a DLL that exports MAPI functions, reads email content. Heuristic scanners cannot distinguish legitimate tools from malicious ones based on behavior alone.

**Concrete example:**
`mailtouiuc` and other legitimate Outlook-alternative projects have been flagged as false positives for years. The `thunderbird-smtp-bridge` project documented a multi-month cycle of submitting to AV vendors for whitelisting.

**How to avoid:**
- Before public release, submit the signed installer to Microsoft's [false-positive reporting](https://www.microsoft.com/en-us/wdsi/filesubmission) and the VirusTotal "false positive" form.
- **Before** submitting, make sure the signed binary has stable hashes and a stable publisher — false-positive reports are per-publisher.
- In the README and installer UI, be upfront: "go-mapi behaves like a mail client because it IS a mail client. Some AV tools may flag it — this is a known false-positive."
- Keep a test matrix of common Windows AVs (Defender, BitDefender, Avast, AVG, Norton, McAfee, ESET) and test each release against at least Defender + one heuristic engine before publishing.
- Consider **not** dropping the DLL to Program Files until first use (delay the visible-to-AV-scanner moment) — but this trades one complexity for another; only worth it if AV false-positives become material.

**Warning signs:**
- VirusTotal shows 2+ engines flagging the installer
- Users report "Defender deleted go-mapi.dll after install"
- Windows Event Log shows `Microsoft-Windows-Windows Defender/Operational` events referencing go-mapi

**Phase to address:** Code signing phase (after first signed build, before any broader distribution). Build a small CI job that uploads each release to VirusTotal API and alerts if detection count goes above 2.

**Confidence:** MEDIUM — heuristic AV behavior is hard to predict; confidence is based on pattern-matching to other MAPI-adjacent FOSS projects rather than direct observation of go-mapi being flagged.

---

### Workstream 3: Native Messaging Manifest (Chrome / Edge / Chromium forks)

#### Pitfall 3.1: Only registering Chrome, silently breaking Edge/Brave/Vivaldi users

**What goes wrong:**
Installer writes the manifest to `HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host`. A user running Microsoft Edge installs the extension from the Edge Add-ons store, clicks the extension, sees "host not found" because Edge looks at `HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host` — a completely different key. Same silent failure on Brave (`BraveSoftware\Brave-Browser`), Vivaldi (`Vivaldi`), Opera (`Opera Software\Opera Stable`), and Chromium (`Chromium`).

**Why it happens:**
Chromium-based browsers share the **manifest format** (same JSON, same allowed_origins rules) but each picks its own registry sub-tree. This is a "who knew" piece of Chromium internals that bites every project that ships native hosts.

**Concrete example:**
Anthropic's Claude Code browser extension (issue #24367): shipped with only Chrome registered, Edge users hit "host not registered" for weeks. KeePassXC-browser issue #48 documents the Vivaldi blind spot. `browserpass-native` maintains an explicit table of all five Chromium registry paths in its installer — a rare example of doing this right.

**How to avoid:**
- At install time, **write the same manifest file path to all known Chromium browser registry keys**, unconditionally. The five keys to cover:
  - `HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host`
  - `HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host`
  - `HKLM\SOFTWARE\Chromium\NativeMessagingHosts\com.gomapi.host`
  - `HKLM\SOFTWARE\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.gomapi.host`
  - `HKLM\SOFTWARE\Vivaldi\NativeMessagingHosts\com.gomapi.host`
- Single manifest file under `%ProgramData%\go-mapi\com.gomapi.host.json`; all five keys point at that one file.
- Document the supported browser list in README. State explicitly which browsers are verified and which are "should work, not tested."
- For Edge specifically, be aware that Edge is distributed by Chrome Web Store **and** Edge Add-ons Store — extension IDs differ between stores. Include **both** extension IDs in `allowed_origins` (see Pitfall 3.3).

**Warning signs:**
- Support reports "I installed go-mapi but the extension still says host missing" from non-Chrome users
- Bug reports mention Edge, Brave, or Vivaldi as the browser
- Telemetry (if any) shows install completion but no `handshake_success` event from certain browsers

**Phase to address:** Installer phase. CI matrix: install on a Windows VM, launch each of {Chrome, Edge} (the two guaranteed via Chrome Web Store + Edge Add-ons), verify `chrome.runtime.connectNative` succeeds in both.

**Sources:** Microsoft Learn Edge native messaging, browserpass-native DeepWiki, Claude Code issue #24367.

---

#### Pitfall 3.2: 32-bit vs 64-bit registry view split silently hides the manifest

**What goes wrong:**
Installer is 32-bit (or uses a 32-bit PowerShell) and writes to `HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host`. On 64-bit Windows, this gets silently redirected to `HKLM\SOFTWARE\WOW6432Node\Google\Chrome\NativeMessagingHosts\com.gomapi.host`. Chrome (64-bit) looks at the non-WOW6432Node tree first and doesn't find it. Depending on version, Chrome may fall back to WOW6432Node, but the behavior is historically unreliable.

**Why it happens:**
32-bit processes on 64-bit Windows get their `HKLM\SOFTWARE` writes silently redirected to `WOW6432Node`. The redirect is invisible to the installer script — `reg query` in the same 32-bit process still shows the "normal" path. Only a 64-bit tool or an explicit `Wow6432Redirect` flag reveals the real location.

**How to avoid:**
- Build the installer as **64-bit native** (Inno Setup's `ArchitecturesInstallIn64BitMode=x64` directive) or use `Wow6432Redirect` to suppress redirection for the specific registry operation.
- For redundancy, write to **both** views — the non-WOW and the WOW6432Node paths. Chrome's registry lookup order (32-bit first, then 64-bit as of current docs) means writing to both is the safe belt-and-braces approach.
- Test on a 64-bit Windows VM with **Task Manager → Processes → Details** to verify the installer process shows `go-mapi-installer.exe` without "(32 bit)" suffix.
- After install, verify the key via `reg query HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts /reg:64` and `/reg:32` to confirm which view it landed in.

**Warning signs:**
- Manifest key exists in `WOW6432Node` but Chrome reports host not found
- `regedit` on 64-bit Windows shows the key only under the WOW6432Node subtree
- Install works on 32-bit Windows 7/8 VMs but fails on 64-bit Win10/11

**Phase to address:** Installer phase. Add an automated post-install check that queries both views and logs which ones contain the key.

**Sources:** Chrome native messaging docs ("first the 32-bit registry is queried, then the 64-bit registry"), chromium-extensions Google Group.

---

#### Pitfall 3.3: `allowed_origins` lists the dev extension ID, not the Chrome Web Store ID

**What goes wrong:**
Developer tests locally by sideloading the unpacked extension (extension ID is a hash of the dev machine's path — e.g., `abcdefghijklmnopqrstuvwxyz123456`). The manifest's `allowed_origins` has `chrome-extension://abcdefghijklmnopqrstuvwxyz123456/`. Release ships. User installs the extension from the Chrome Web Store — the real extension ID is completely different (e.g., `pqrstuvwxyz1234567890abcdefghijk`). `allowed_origins` check fails in the host, handshake is silently rejected, user sees "host disconnected."

**Why it happens:**
Sideloaded extensions get IDs derived from the install path; Web Store extensions get IDs derived from a key Chrome assigns at first publication. These are unrelated. The dev-to-prod ID change is invisible unless you explicitly check.

**How to avoid:**
- Fix the extension ID across dev and prod by embedding a `"key"` field in `manifest.json` (see Chrome docs on "keeping extension ID constant"). This makes sideloaded and Web Store IDs identical.
- In `allowed_origins`, list **every** ID go-mapi might be published under:
  - Chrome Web Store ID
  - Edge Add-ons Store ID (different from Chrome's, even for the same extension)
  - Developer sideload ID (if the `"key"` trick is used, this is the same as the Web Store ID)
- Add a CI check that reads `manifest.json` and `com.gomapi.host.json.template`, diffs the extension IDs, and fails if any are mismatched or missing.
- Document this in `CONTRIBUTING.md` — next maintainer who publishes a new extension version must update allowed_origins.

**Warning signs:**
- Handshake works for developer (sideloaded) but fails for user (Web Store)
- Chrome DevTools console shows `Disconnected: [native host] rejected the connection`
- Go host logs show `origin mismatch: expected chrome-extension://X/, got chrome-extension://Y/`

**Phase to address:** Installer phase (manifest generation logic) **and** handshake phase (CI gate).

**Sources:** Chrome native messaging docs, Microsoft Edge native messaging docs.

---

#### Pitfall 3.4: Manifest path contains spaces, quotes, or non-ASCII and silently breaks

**What goes wrong:**
Manifest's `"path"` field points to `C:\Program Files\go-mapi\go-mapi-host.exe`. On some Chrome versions or locales, the space in "Program Files" is not handled and the path resolves to `C:\Program` (file not found) or worse, something in the user's locale path like `C:\Archivos de programa\...` on Spanish Windows. Similarly, non-ASCII in a user's profile path (`C:\Users\Müller\...`) breaks the manifest JSON parser if not UTF-8 encoded.

**Why it happens:**
Manifest `"path"` is documented as "full path" but the behavior around spaces has historically been inconsistent (fixed in later Chrome versions but backported behavior varies). JSON must be UTF-8 encoded — Windows tools often write UTF-16 or CP1252 by default.

**How to avoid:**
- Install to `%ProgramData%\go-mapi\` — a path without spaces — instead of `%ProgramFiles%\go-mapi\`. Tradeoff: less discoverable, but more robust.
- Always write `com.gomapi.host.json` as **UTF-8 without BOM**. In Inno Setup, use `[Files]` with `LoadStringsFromFile` + `SaveStringsToFile` with explicit UTF-8 flag, not `[INI]` which may default to ANSI.
- In the manifest, double-check that the path uses **forward slashes** or **escaped backslashes** (`C:\\ProgramData\\go-mapi\\go-mapi-host.exe`). JSON rejects single backslashes; this is the second most common manifest-generation bug after missing extension ID.
- Test on a Windows VM with a non-ASCII username to confirm encoding works.

**Warning signs:**
- Installer finishes but host never connects on machines with non-English Windows
- `native-host.log` never appears (process never launched)
- Chrome DevTools shows `Error when communicating with the native messaging host` immediately on `connectNative`

**Phase to address:** Installer phase. CI matrix should include at least one non-English Windows VM (Spanish or German) to catch locale-specific issues.

**Sources:** Chrome bug tracker, chromium-extensions Google Group (issue about relative paths on Windows).

---

### Workstream 4: Extension Handshake + Reconnect Logic

#### Pitfall 4.1: Can't distinguish "host not installed" from "host crashed" from "service worker went idle"

**What goes wrong:**
All three failure modes fire `port.onDisconnect` with `chrome.runtime.lastError.message` like `"Native host has exited"` or `"Specified native messaging host not found"` or `"Access to the specified native messaging host is forbidden"`. The extension popup needs completely different UX for each:
- **Not installed** → show "Install go-mapi" button with download link
- **Crashed / transient** → silently reconnect with backoff, don't alarm user
- **Service worker idle** → reconnect silently, don't even log

If the extension treats all three as "not installed," users who just experienced a transient reconnect see an "Install" prompt and re-run the installer over a working install. If it treats all three as "crashed" and retries, users without the host ever see only a spinner.

**Why it happens:**
Chrome's native messaging API exposes only one signal — `chrome.runtime.lastError.message` — and the message strings are implementation-defined and have drifted between Chrome versions. There is no structured error code.

**How to avoid:**
- Parse `chrome.runtime.lastError.message` **as a heuristic**, explicitly mapping known strings:
  - `"Specified native messaging host not found"` → `HOST_NOT_INSTALLED`
  - `"Native host has exited"` → `HOST_CRASHED` (retry)
  - `"Access to the specified native messaging host is forbidden"` → `ALLOWED_ORIGINS_MISMATCH` (don't retry; show diagnostic)
  - Anything else → `HOST_UNKNOWN_ERROR` (retry once, then show generic diagnostic)
- Track error message coverage: log unknown error messages to console with `[go-mapi] unknown disconnect reason: ${msg}` so Marc can add them to the heuristic list as Chrome evolves.
- Use a **state machine**: `UNKNOWN → CONNECTING → CONNECTED → DISCONNECTED_RETRYING → HOST_MISSING`. Transitions drive UX. Never jump directly from CONNECTED to HOST_MISSING without at least one retry attempt.
- Give the user an explicit "Check again" button in the install prompt so they can force a transition out of HOST_MISSING without waiting for the 6-second alarm.

**Concrete example:**
Anthropic's Claude Code browser extension issue #16350: service worker going idle was misidentified as host crash; extension showed "host disconnected" toast every few minutes even though the bridge was healthy. Fix required distinguishing the two cases.

**Warning signs:**
- Beta users report "install prompt keeps popping up randomly"
- Console spam of reconnect attempts in a working install
- Users re-run installer thinking there's a bug when the host was fine

**Phase to address:** Handshake phase. Unit-test the error-string → state mapping. Capture Chrome version in error reports so drift can be detected.

**Sources:** Chrome for Developers service worker lifecycle docs, Claude Code issue #16350, chromium-extensions Google Group discussions on MV3 unreliability.

---

#### Pitfall 4.2: Install prompt shows "download" link but extension can't detect when install completes

**What goes wrong:**
User clicks the "Install" button in the extension popup, downloads the installer, runs it, installer succeeds. User returns to the extension popup — still shows "host not installed." Manual reload of the extension (chrome://extensions → reload) is required. User assumes install failed, re-runs installer, maybe files a bug.

**Why it happens:**
The service worker cached the HOST_MISSING state. MV3 service workers **don't automatically poll** — they wake on events. No event fires when a registry key changes. The extension needs to be told "check again" either by a user action or a scheduled alarm.

**How to avoid:**
- Set up a `chrome.alarms` alarm for every 5 seconds while in HOST_MISSING state (cap after 2 minutes — user probably left the page). On each alarm, attempt `connectNative` silently; if it succeeds, transition to CONNECTED and show the success toast.
- **Also** add a `chrome.windows.onFocusChanged` listener so that when the user Alt-Tabs back to the browser after installing, the extension retries immediately without waiting for the alarm.
- On successful reconnection, fire a Chrome notification (`chrome.notifications.create`) so the user sees "go-mapi connected — you can now send to Gmail" **even if the popup is closed**.
- Be careful not to spam notifications: only fire the success notification once per HOST_MISSING → CONNECTED transition, not on every reconnect.

**Warning signs:**
- Users report "I installed but the extension doesn't know — I had to reload it"
- Telemetry shows `install_clicked` events with no corresponding `host_connected` within 60 seconds
- GitHub issues titled "does installer even work?"

**Phase to address:** Handshake phase. E2E test scenario: start with host not installed, trigger install flow, verify extension auto-detects within 10 seconds of installer completion.

---

#### Pitfall 4.3: Reconnect logic amplifies a crash loop into a DoS of the user's machine

**What goes wrong:**
Go host has a startup bug that crashes immediately after sending the `READY` message. Extension sees `onDisconnect`, reconnects after 6-second backoff, host crashes again, extension reconnects, infinite loop. Each reconnect spawns a new Go process (launched by Chrome). If the crash is fast (< 1 second) and backoff is linear or insufficient, the user's machine gets hammered with process spawns.

**Why it happens:**
Linear backoff without a circuit breaker. Existing v1.0.0 code uses a fixed 6-second backoff, which is fine for occasional disconnects but catastrophic for fast crashes.

**How to avoid:**
- Use **exponential backoff with jitter**: 1s, 2s, 4s, 8s, 16s, 30s, capped at 60s.
- Implement a **circuit breaker**: after 5 consecutive reconnect failures, stop retrying automatically and transition to a `HOST_FAILING` state with a user-facing error and a "Retry" button.
- Distinguish "crashed before READY" from "crashed after READY": if the host never gets to READY, the problem is a startup bug, not a transient — break the circuit faster.
- Log reconnect attempts with timestamps so users can report the pattern: "it's trying every second for a minute."

**Warning signs:**
- User's Task Manager shows `go-mapi-host.exe` appearing and disappearing rapidly
- `native-host.log` grows by MB per minute with repeated startup messages
- CPU usage spike from Chrome's native messaging infrastructure

**Phase to address:** Handshake phase. Unit-test the reconnect state machine with a mocked Port that fires `onDisconnect` synchronously.

---

### Workstream 5: Test Audit Methodology

#### Pitfall 5.1: The "coverage %" trap — chasing a number instead of blast radius

**What goes wrong:**
Audit starts with `go test -coverprofile=c.out` showing 65% coverage. Team sets a goal of "80% by end of milestone." To hit it, people write tests for trivial getters, logging functions, and formatting helpers — the easy stuff. Meanwhile, `buildFullMIME` (complex, high blast radius, untested at 0% file coverage) stays untested because adding a real test for it is hard. Coverage goes up, but the actual risk profile is unchanged.

**Why it happens:**
Coverage is easy to measure, easy to game, and feels productive. Mutation-testing research shows that coverage has weak correlation with defect-finding ability because it measures execution, not assertion quality.

**Concrete example from this codebase:**
`TESTING.md` reports protocol layer at ~95% coverage but `buildFullMIME` at 0%. The 95% number is a trap — it obscures that the highest-risk function in the system has no direct tests. `buildFullMIME` is where RFC 2822 bugs live (see Pitfall 5.2).

**How to avoid:**
- **Do not set a numeric coverage goal.** PROJECT.md already rejects this — keep it rejected.
- Instead, produce a **gap list ranked by blast radius**: for each untested function, ask "if this silently breaks, what happens?" Rank by consequence, not by line count.
- For this codebase specifically, the audit should prioritize (in order):
  1. `buildFullMIME` — silent data corruption = user's drafts have garbled subjects, missing attachments, broken MIME
  2. Gmail API HTTP client (no tests, no mocking) — silent failure = drafts lost
  3. Extension service worker connection handling — reliability black hole
  4. C++ DLL message conversion — corrupted data at ingress
  5. `handleCreateDraft` goroutine lifecycle — race between draft creation and shutdown
  6. `moveToErrors` atomicity — bad files accumulate
  7. `normalizeAddress` edge cases (Unicode prefixes, custom MAPI types)
  8. Logging functions — low blast radius, defer
- For each high-blast-radius function, write **at least one test per failure mode** that matters, not a single happy-path test.
- Consider running mutation testing (e.g., `go-mutesting`) on the top-3 files to verify the tests actually catch mutations — not required, but a useful reality check if time allows.

**Warning signs:**
- PR descriptions say "raises coverage from X% to Y%" instead of "tests scenario Z"
- Tests that pass when assertions are deleted (classic coverage-trap signature)
- Tests that don't fail when the function body is replaced with `return nil` (failed mutation test)

**Phase to address:** Test audit phase. Produce the gap list **before** writing any tests, so prioritization is explicit.

**Sources:** Codecov blog on mutation vs coverage, Trail of Bits mutation testing guide, Stryker Mutator docs.

---

#### Pitfall 5.2: `buildFullMIME` tests that only cover ASCII happy path miss real-world breakage

**What goes wrong:**
Someone finally writes tests for `buildFullMIME`. They use a test email with subject `"Hello"`, body `"Test"`, and an attachment `test.txt`. All tests pass. In production, a French user sends an email with subject `"Élément à réviser — priorité haute"` and the Gmail draft shows `"=?UTF-8?B??= l=C3=A9ment"` (broken RFC 2047 encoding). Or a user attaches a file with a space in the filename and the Content-Disposition header breaks.

**Why it happens:**
RFC 2822 / RFC 2047 header encoding is hard. The "obvious" approach — just put UTF-8 bytes in the subject — violates the ASCII-only header rule and some clients render garbage. The correct approach is `=?UTF-8?B?<base64>?=` (or `=?UTF-8?Q?<quoted-printable>?=`) encoded-word syntax, with 75-character line length limits, and folding rules for long headers. Multipart boundary strings must not appear in the body. Attachment filenames with non-ASCII need RFC 2231 continuation encoding.

**Relevant CONCERNS.md entry:** "Charset encoding in MIME headers — not tested. Risk: Email headers may be corrupted for international users."

**How to avoid:**
- Test `buildFullMIME` with a deliberate matrix of inputs:
  - ASCII subject, ASCII body, no attachments (baseline)
  - UTF-8 subject with accented Latin characters (French, Spanish)
  - UTF-8 subject with CJK characters (Japanese, Chinese)
  - Subject longer than 75 characters (tests header folding)
  - Subject containing `=?` (tests that the encoder doesn't double-encode its own output)
  - Attachment with space in filename
  - Attachment with UTF-8 filename
  - Multipart with body containing a string that looks like a boundary (e.g., `--boundary`) — tests that boundary generation uses sufficient randomness
  - Multiple attachments
  - Large attachment (> 1MB) to test memory behavior
  - Recipient name with UTF-8 characters in `To: "Müller, Hans" <hans@example.com>`
- Use **golden files** (Go idiomatic `testdata/` directory with `.eml` files as expected output). On mismatch, write the actual output to `testdata/actual/` for diffing.
- Verify each golden file against a real email parser (e.g., Go's `net/mail.ReadMessage` or Python's `email` library as a cross-check) in one meta-test, so golden files can't drift into non-RFC-compliant shapes.

**Warning signs:**
- Draft created but Gmail web UI shows `=?UTF-8?B?...?=` literally in the subject
- Attachment filenames are `filename?=` or similarly broken in the draft
- Non-ASCII body renders as mojibake

**Phase to address:** Test audit phase (gap filling sub-phase).

---

#### Pitfall 5.3: Gmail HTTP client tests mock too shallow and miss real API quirks

**What goes wrong:**
Developer writes tests that mock the `http.Client` with a canned `{"id": "draft_123"}` response. Tests pass. In production, Gmail API rate-limits the user, returns `429` with a retry-after header, and the client doesn't handle it. Or returns `401 Unauthorized` with a structured error body explaining the token is expired — client treats all errors as generic failures and loses the distinction.

**Why it happens:**
Shallow mocks test "my code calls the mock correctly," not "my code handles what Gmail actually sends." Real API behaviors (rate limiting, partial success, error body shapes) are never exercised.

**How to avoid:**
- Use `httptest.NewServer` with realistic handlers that return actual Gmail API response shapes — copy real responses from Gmail API documentation or from live API calls, stored as `testdata/gmail-responses/*.json`.
- Test at least these scenarios:
  - 200 with valid draft ID (happy path)
  - 401 with `{"error": {"code": 401, "message": "Invalid Credentials"}}` (token expired) → must surface as distinct error for re-auth prompt
  - 403 with `{"error": {"code": 403, "errors": [{"reason": "rateLimitExceeded"}]}}` (quota) → must back off
  - 429 with `Retry-After: 30` header → must respect
  - 500 / 503 transient (must retry)
  - 400 with `{"error": {"code": 400, "message": "Invalid message"}}` (malformed MIME — tests that buildFullMIME output is accepted)
  - Timeout (relates to CONCERNS.md missing HTTP timeout) — test must configure a short timeout and verify it triggers
  - Network error (connection refused) — test by pointing client at a closed port
- Fixture-load real Gmail error response bodies (not fabricated structures) — Google's error envelope shape has wrinkles that are easy to miss.

**Warning signs:**
- Tests mock with generic `map[string]any` instead of strongly-typed Gmail structures
- Tests don't include a timeout assertion
- Tests don't differentiate `401` (re-auth) from `403` (permissions) from `429` (rate limit)

**Phase to address:** Test audit phase. Combine with the CONCERNS.md "missing HTTP timeout" fix — writing the test drives the timeout implementation.

**Sources:** Stellar Go httptest patterns, Mark Phelps "Testing API Clients in Go."

---

#### Pitfall 5.4: Extension TypeScript tests mock Chrome APIs so loosely they don't catch real Chrome behavior

**What goes wrong:**
Team writes tests using `jest` with `chrome = { runtime: { connectNative: jest.fn() } }` style manual mocks. Tests pass. In production, real Chrome's `connectNative` behaves differently — e.g., `port.onDisconnect` can fire **before** any message is sent (host fails to start), which the tests never exercised because the mock only fires `onDisconnect` after `postMessage`.

**Why it happens:**
Manual mocks encode developer assumptions about Chrome's API, not Chrome's actual behavior. Real Chrome has edge cases (onDisconnect-before-onMessage, port.error on Firefox but not Chrome, sendMessage vs port.postMessage semantics) that never show up in hand-written mocks.

**How to avoid:**
- Use a well-maintained Chrome API mock library (e.g., [`jest-chrome`](https://github.com/extend-chrome/jest-chrome) or [`sinon-chrome`](https://github.com/acvetkov/sinon-chrome)) rather than hand-written mocks. These libraries encode real-ish Chrome semantics.
- For the handshake logic specifically, prefer **integration tests via Playwright** (see workstream 7) over unit tests with mocked Chrome — Playwright runs real Chrome with the real extension, so no mock can lie.
- Unit test only the **pure business logic** (state machine transitions, error-string → state mapping, email queue state management) with all Chrome calls injected via dependency injection.
- Keep pure logic separated from Chrome API calls — refactor if necessary. This mirrors the Go code's `NativeMessaging` interface pattern already used in the codebase.

**Warning signs:**
- Tests pass but a real install exposes bugs
- Mock setup is 50+ lines per test file
- Tests that test "my mock was called" without testing behavior

**Phase to address:** Test audit phase (TypeScript gap sub-phase).

---

### Workstream 6: Race Detector Rollout

#### Pitfall 6.1: Enabling `-race` in CI surfaces existing races that fail builds on day one

**What goes wrong:**
CI is modified to run `go test -race ./...`. The very next PR's CI fails — not because of the PR's changes, but because `-race` finally detected the pre-existing race in `handleCreateDraft` goroutine access to the `emails` map (already documented in CONCERNS.md). Every subsequent PR fails until the race is fixed. Developers start adding `-short` flags or disabling the race detector to unblock, which defeats the purpose.

**Why it happens:**
`-race` doesn't cause races — it exposes ones that were already there. A codebase that was never tested under `-race` has unknown races by definition. This codebase has at least one known race (goroutine access to `emails` map) and likely more.

**Concrete plan to avoid:**
1. **Before enabling in CI,** run `go test -race ./...` locally and triage the output:
   - How many races fire? Which files?
   - Are any of them false positives (e.g., fsnotify has known false-positive races on Windows)?
   - How many need code changes vs. test-only changes?
2. **Fix the races one at a time**, each in its own commit, before enabling `-race` in CI. Specifically address:
   - CONCERNS.md entry: `handleCreateDraft` goroutine accesses `emails` map outside the `EmailWatcher` mutex — needs immutable copy or explicit lock.
   - CONCERNS.md entry: goroutine lifecycle not tracked with WaitGroup — may not be a race, but is a data-loss bug in the same area.
   - Any fsnotify-related races — may need to be suppressed via `go:build !race` on a specific test file if fsnotify itself races.
3. **Then enable `-race` in CI** as a separate job (not replacing the existing non-race job — run both so test time stays manageable).
4. Run race CI on a dedicated Windows runner — the watcher has Windows-specific fsnotify behavior that Linux can't exercise.

**Known race to start with:** The `emails` map race in `watcher.go` / `main.go` — there is literally already a bug documented for it in `CONCERNS.md`. Fix that first, measure whether `-race` is now clean, then enable CI.

**Warning signs:**
- `-race` CI job is red from day one (predictable)
- Developers start skipping `-race` locally because it's slow
- Flaky race failures that don't reproduce locally (classic Windows CI symptom)

**Phase to address:** Test audit phase, but ordered: **fix races → then add CI**, not the other way around.

**Sources:** Go race detector docs, Tailscale flakytest package, Bitfield Consulting "Slow, flaky, and failing."

---

#### Pitfall 6.2: Race detector on GitHub Actions `windows-latest` runners is 15-30x slower than Linux

**What goes wrong:**
Adding `-race` to the Windows Go test job in CI inflates test time from ~30 seconds to 5+ minutes. Combined with the already-slow Windows runner I/O (15x slower than Linux for `go test`), the feedback loop becomes unusable. Developers start waiting 10+ minutes for CI feedback, morale drops, people merge without waiting.

**Why it happens:**
- Race detector adds 2-20x runtime overhead per the official Go docs.
- Windows GitHub Actions runners are 15x slower than Linux runners for I/O-heavy workloads.
- These multiply, not add. A 30-second Linux test becomes a 5-10 minute Windows race test.

**How to avoid:**
- Run **the main CI job without `-race`** — keep it fast (the existing `go test -v ./...` job).
- Run **a separate `race-windows` job** that runs only on push to main (or nightly) — not on every PR. This keeps PR feedback fast.
- Alternatively, run `-race` on **Linux** for every PR (much faster) and only on Windows nightly. The Go race detector is platform-independent in what it catches, so Linux catches most races. Reserve Windows races for the known platform-specific ones (fsnotify).
- Use `-race -short -timeout 5m` and ensure test cases tagged `testing.Short()` skip the slowest scenarios.
- If CI time is still a problem, consider a self-hosted Windows runner or a paid faster runner like BuildJet — but only if the free option is provably blocking.

**Warning signs:**
- PR CI takes > 5 minutes
- Developers complain about CI speed
- Race CI job times out at the GitHub Actions default 6-hour limit

**Phase to address:** Race detector rollout sub-phase. Benchmark the race job on Linux and Windows before committing to a CI topology.

**Sources:** GitHub Actions runner-images issue #7320, chadgolden.com blog on Windows runner slowness, Go runtime docs on race detector overhead.

---

### Workstream 7: E2E Test Design

#### Pitfall 7.1: Playwright E2E tests need `headless: false` + Xvfb on Linux CI

**What goes wrong:**
Team writes Playwright E2E tests for the Chrome extension. Tests pass locally (headed). Push to CI — all tests fail because Chrome extensions **do not work in headless mode**. Developer adds `--headed` or `headless: false` — tests now fail with "no display found" because `ubuntu-latest` runners have no X server by default.

**Why it happens:**
Chrome extensions require a full browser process with a real renderer, which the headless mode (especially the pre-new-headless mode) does not provide. Loading an unpacked extension via `--load-extension=` requires headed. On Linux CI, headed requires Xvfb or similar.

**How to avoid:**
- Run Playwright tests with `headless: false` and wrap Chrome in Xvfb on Linux: `xvfb-run playwright test`.
- Alternatively, run E2E tests on **Windows runners** where the graphical desktop is available without Xvfb — matches the actual production platform too, so higher fidelity.
- In the Playwright config, set the browser launch with `args: ['--load-extension=dist/extension', '--disable-extensions-except=dist/extension']`.
- Verify that the extension's service worker starts — if there's no background script and no service worker, Playwright may time out waiting for the extension to initialize. Add a stub background page if necessary.
- Use `chrome-extension://<id>/popup.html` as a navigation target — this lets Playwright drive the popup UI without needing to click the toolbar icon (which Playwright cannot access directly).

**Warning signs:**
- "Timed out waiting for service worker" in Playwright output
- "No display available" errors on Linux CI
- Tests pass locally (where you have a real display) but fail on CI

**Phase to address:** E2E test phase.

**Sources:** Playwright docs on Chrome extensions, DEV Community article "E2E Tests for Chrome Extensions," kelseyaubrecht/playwright-chrome-extension-testing-template.

---

#### Pitfall 7.2: E2E test for the happy path depends on real Gmail API (OAuth, drafts, cleanup)

**What goes wrong:**
E2E test "user clicks Save as Draft, verify draft appears in Gmail." To actually verify, the test needs to:
- Complete real Chrome OAuth flow (`chrome.identity.getAuthToken`)
- Have a test Google account with Gmail API access
- Clean up created drafts after the test (otherwise the test account's Drafts folder fills up)
- Not rate-limit itself against the free Gmail quota
- Run in CI without exposing credentials

This is a massive scope expansion from "test the bridge" to "test real Gmail integration." Teams either skip the real-API verification (reducing E2E value to zero) or ship credentials to CI (security risk).

**Why it happens:**
"Happy path E2E" is usually imagined as end-to-end, but a literal end-to-end test crosses the OAuth boundary, which is the hardest part of any integration test.

**How to avoid:**
- **Split the E2E test in half:**
  1. **Local happy path E2E:** MAPI call (via a test harness that writes a JSON file directly to the watch dir, simulating the DLL) → Go host → extension popup shows email → user clicks Save as Draft → Gmail API call is intercepted by a local httptest server → server returns fake draft ID → extension shows success. This tests the bridge, the handshake, the popup UI, the draft flow — without touching real Gmail. **This is the test to write.**
  2. **Periodic real-Gmail smoke test:** A separate, manually triggered (or nightly) test that uses a dedicated test Google account with a scoped OAuth token, creates one draft, deletes it. Runs rarely, is allowed to be flaky, provides reality check.
- Use `chrome.identity.getAuthToken` mock by injecting a fake token when running in E2E mode (detect via a manifest flag or a test-mode env var).
- Intercept Gmail API calls by configuring the Go host with a test base URL (add a `--gmail-api-base` flag or env var, defaulting to `https://gmail.googleapis.com`). Playwright test sets this to point at an httptest server.
- Do **not** run real OAuth in main E2E — it's flaky, rate-limited, credential-dependent, and tests the wrong thing.

**Warning signs:**
- E2E tests break when Google rotates OAuth flows
- E2E tests leak drafts into a real Gmail account
- CI has Google credentials in secrets (security exposure)
- E2E test is flaky for reasons unrelated to go-mapi

**Phase to address:** E2E test phase. Architecture decision up front: mocked Gmail for E2E, separate nightly real-API smoke.

---

#### Pitfall 7.3: E2E test uses filesystem IPC and races itself on Windows CI

**What goes wrong:**
The E2E test writes a JSON file to `%TEMP%\go-mapi\` to simulate a MAPI call, then waits for the extension popup to show the email. On Windows CI runners, file system events are delayed, AV is running, the 500ms debounce combines with CI disk latency to produce 2-3 second delays. Test waits 1 second, times out, fails. Developer increases timeout to 5 seconds. Next week, a slow runner takes 6 seconds, test fails again. Endless timeout tuning.

**Why it happens:**
Windows GitHub Actions runners have unpredictable I/O latency. Test was designed with "sleep N seconds" instead of "poll until condition."

**How to avoid:**
- Use Playwright's `expect.poll` or `waitForFunction` with generous upper bounds (10-30 seconds) and a **condition check**, not a fixed sleep. This is the standard advice from Go flaky-test guidance (Bitfield Consulting), restated for Playwright.
- Write the JSON file **atomically**: write to `<id>.json.tmp`, then rename to `<id>.json`. This avoids the debounce waiting for write stabilization — rename is atomic.
- Avoid the 500ms debounce entirely in E2E by passing a `--watcher-debounce=0` flag to the Go host when running in test mode. The debounce exists for AV compatibility; tests can opt out.
- Quarantine flaky E2E tests: mark them with a tag, don't let them fail the PR build, but surface them in a dashboard so they get fixed rather than ignored.
- Don't use `page.waitForTimeout(N)` — ever. It's the #1 source of flaky Playwright tests.

**Warning signs:**
- Test sometimes passes, sometimes fails with no code changes ("flaky")
- Test passes locally, fails on CI
- Timeout values in the test keep getting bumped up

**Phase to address:** E2E test phase. Code review gate: any PR that adds `waitForTimeout` gets rejected.

---

### Workstream 8: CI on Windows Runners

#### Pitfall 8.1: CI builds the Windows artifact on Linux, ships untested

**What goes wrong:**
GitHub Actions CI uses `ubuntu-latest` + MinGW cross-compilation to build the Windows installer because Linux is cheaper/faster. The installer is built successfully but never **run** in CI — no smoke test that the installer actually works on a real Windows machine. A typo in a registry key, a missing DLL dependency, a path encoding bug — all ship undetected because only a Windows environment would catch them.

**Why it happens:**
Linux builds are fast and cheap. Windows runners are slow and expensive. Teams optimize for build time without thinking about coverage.

**How to avoid:**
- CI **must** have at least one `windows-latest` job that:
  1. Downloads the built installer artifact
  2. Runs it silently (`go-mapi-installer.exe /SILENT` for Inno Setup, `msiexec /i /quiet` for MSI)
  3. Verifies all five registry trees are populated (Chrome, Edge, Chromium, Brave, Vivaldi)
  4. Verifies files exist at expected paths
  5. Launches the Go host manually and checks it responds to a simple `LIST` native messaging request via stdin/stdout
  6. Runs the uninstaller
  7. Verifies clean teardown
- This smoke test runs on every PR to main (not every commit, to save cycles). Runtime budget: ~3-5 minutes.
- Build on Linux **if you want**, but **verify on Windows** — always.

**Warning signs:**
- Installer has been green in CI for weeks but the first real user hits a bug immediately
- Bug reports include "worked on my dev box but not after install"
- CI never actually executes the installer

**Phase to address:** CI / Windows runner phase. This is non-negotiable.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Ship unsigned, defer signing to later | Release this week | Each user gets SmartScreen red-screen; trust erosion; painful to sign retroactively because reputation must be rebuilt | OK for pre-beta private testing only; **not** for first public release — start SignPath application in parallel with installer work |
| Only support Chrome, skip Edge/Brave/Vivaldi manifest registration | Simpler installer, fewer registry keys to test | Edge users silently broken forever (bug reports blame go-mapi generically); re-adding later requires a full installer refresh cycle | Never — writing 5 keys is ~10 extra lines in Inno Setup |
| Hand-write Chrome API mocks in TypeScript tests | Fast to start | Tests encode wrong assumptions; prod bugs missed; mocks drift from reality | For pure business logic with injected Chrome deps only; for handshake code, use Playwright instead |
| Hit real Gmail API in E2E tests | "True" end-to-end confidence | Flaky tests, credential management, rate limits, leaked test drafts | Only as a periodic/nightly smoke test, never in PR CI |
| Enable `-race` in CI before fixing existing races | Forces race fixes to happen | Red CI blocks unrelated PRs until all races are fixed | Never — fix races first, then turn on CI as a regression gate |
| Test `buildFullMIME` only with ASCII inputs | Fast test write | Silent breakage for non-English users, multi-attachment edge cases, long subject lines | Only as the first in a series — must follow up with the full matrix |
| Use linear backoff for native host reconnect | Simple code | Crash-loop amplification when host has a fast-crash bug | Only with an explicit max-attempts circuit breaker |
| Skip the post-install smoke test on Windows CI | Faster CI pipeline | Every installer regression ships to users undetected | Never — Linux-only verification of a Windows installer is effectively no verification |
| Write the manifest to HKCU only | Works for dev machine | Fails under UAC-elevated installer, fails for admin-install / user-run scenarios | Never for this project — always HKLM because installer is elevated |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Chrome Web Store | Hardcoding the dev sideload extension ID in `allowed_origins` | Embed `"key"` in manifest.json to make dev ID == Web Store ID; list both Chrome + Edge store IDs |
| Edge Add-ons Store | Assuming Edge extensions share IDs with Chrome versions of the same extension | Edge assigns its own ID; must be added to `allowed_origins` separately |
| Chromium forks (Brave, Vivaldi, Opera) | Only registering under `HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts` | Register under each browser's registry tree; all can share a single manifest JSON file |
| GitHub Releases (for direct download URL) | Linking to `/releases/latest/download/...` expecting no redirect | `/releases/latest/download/` returns HTTP 302; either accept redirects in the extension fetch or use GitHub API to resolve the direct URL first |
| Gmail API | Treating all HTTP errors as generic failures | Distinguish 401 (re-auth), 403 rateLimitExceeded (backoff), 429 (respect Retry-After), 5xx (retry), 400 (surface MIME error) |
| Chrome Identity API | Assuming `getAuthToken` returns quickly | First call triggers OAuth consent UI — takes 10-60 seconds; cache-first, interactive-fallback pattern is required |
| Windows MAPI | Assuming `MAPISendMail()` callers pass ANSI strings | Must handle both `MAPISendMail()` (ANSI) and `MAPISendMailW()` (Unicode); failing to export `W` variant silently breaks for apps that use Unicode |
| Inno Setup `[Registry]` | Using `root: HKCU` in an admin-required installer | `HKCU` resolves to the Administrator's profile, not the user's — use HKLM or `runasoriginaluser` |
| fsnotify on Windows | Assuming file events fire once per file write | Windows + AV combinations fire multiple events per write; debouncing is mandatory (already done in v1.0.0 — don't remove) |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| `-race` + Windows CI without job separation | PR feedback time > 5 min | Run `-race` on Linux for PRs, Windows nightly only | As soon as `-race` is added to `windows-latest` |
| Playwright E2E with fixed `waitForTimeout` | Flaky test failures on slow runners | Use `expect.poll` with condition-based waiting | Intermittent from day one |
| Linear reconnect backoff in extension | CPU spike, process-spawn storm | Exponential backoff + circuit breaker | As soon as host has a startup bug |
| Writing full `emails` map to `chrome.storage.session` per change (already in CONCERNS.md) | Popup UI lag as queue grows | Sparse updates, or move to IndexedDB | ~100 emails |
| Attachment full-load into memory in `buildFullMIME` (already in CONCERNS.md) | Memory spike, OOM on large attachments | Streaming base64 encoder | 25 MB attachments |
| Installer verifying with `go test -race` as the only test job | CI blocks on race failures, no fast feedback | Separate race job from main test job | Immediately after adding `-race` |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Writing manifest under user-writable path (`%LOCALAPPDATA%`) | Malicious local process tampers with manifest, redirects to attacker binary | Install under `%ProgramData%\go-mapi\` with admin-only write ACL; rely on HKLM registry protection |
| Leaving `allowed_origins` with a wildcard or dev-only extension ID in release | Unauthorized extensions can invoke the native host | CI gate: fail build if `allowed_origins` doesn't contain exactly the Chrome + Edge store IDs |
| Unsigned installer distributed via HTTP download URL | MITM can replace installer with malware | Direct-download URL must be HTTPS; use GitHub Releases or a CDN with TLS |
| Signed installer with an expired / revoked cert | Signature validation fails loudly; users panic | If using SignPath Foundation, monitor cert expiry; renewal is their responsibility but verify on each release |
| Shipping `.pdb` or debug symbols alongside the installer | Reverse engineering + potential info leak from debug strings (log paths, dev machine usernames) | Strip symbols in the release build (`go build -ldflags "-s -w"` already in use — verify it stays) |
| Native host logs containing email subjects (already in CONCERNS.md) | Log file at `%TEMP%\go-mapi\native-host.log` leaks subjects to other users on shared systems | Log only anonymized IDs; add a privacy mode flag |
| Installer dropping DLL without verifying it against a manifest hash | Post-install tampering replaces DLL with a hostile version | ACL the install directory to admin-write only; rely on signed DLL as integrity proof |

---

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Extension popup shows "host not installed" even during brief reconnect windows | User re-runs installer unnecessarily, confused | State machine with a `CONNECTING` state that shows a spinner, only falls back to `HOST_MISSING` after 2+ failed reconnects |
| Install button opens GitHub Releases page (shows changelog, commit list, asset tree) | Non-technical users confused, click wrong asset, or download source zip | Install button is a direct `.exe` download link; a "see release notes" secondary link for curious users |
| SmartScreen warning with no guidance | First-time users think it's malware, abandon install | Pre-install docs page with screenshots of the exact SmartScreen dialog and circled "More info" link; link from extension popup |
| No feedback during installer run (silent install) | User thinks the installer is frozen | Show a progress dialog (Inno Setup default) with concrete steps: "Copying files... Registering MAPI handler... Writing native messaging manifest..." |
| Success toast shows after every reconnect, not just first successful install | Notification fatigue; user dismisses all toasts reflexively | Fire success toast only once per HOST_MISSING → CONNECTED transition, not on routine reconnects |
| Uninstall leaves `%TEMP%\go-mapi\` files behind | User manually finds them months later, worried about privacy | `[UninstallDelete]` explicit directive for all go-mapi temp dirs |
| Installer asks user where to install | Non-technical users don't care and pick wrong paths | Fixed install path (`%ProgramFiles%\go-mapi\` or `%ProgramData%\go-mapi\`); hide the directory chooser |
| Install flow assumes Chrome / ignores Edge users | Edge user installs, nothing works, gives up | Installer detects which Chromium browsers are present and registers for all of them; README lists supported browsers |

---

## "Looks Done But Isn't" Checklist

- [ ] **Installer:** Registers native messaging manifest for Chrome **and** Edge **and** Chromium + Brave + Vivaldi — verify by running `reg query` on all five keys post-install
- [ ] **Installer:** Uninstall removes the MAPI handler registration under `HKLM\SOFTWARE\Clients\Mail\go-mapi` — verify by checking Default Apps → Email does not list go-mapi
- [ ] **Installer:** Works when UAC is enabled and the invoking user is a standard (non-admin) user — verify on a VM with a separate non-admin test account
- [ ] **Installer:** Manifest file is UTF-8 without BOM, with forward slashes or escaped backslashes in the `path` field — verify with `file` / hex dump
- [ ] **Installer:** Direct download URL is HTTPS and stable (not `latest` redirects if the extension can't follow them)
- [ ] **Installer:** Built as 64-bit; registry writes land in the non-WOW6432Node tree — verify with `reg query /reg:64`
- [ ] **Signing:** SignPath Foundation application submitted (if pursuing); fallback unsigned guide ready with exact SmartScreen screenshots
- [ ] **Signing:** VirusTotal scan of the signed installer shows ≤ 1 detection
- [ ] **Handshake:** Extension distinguishes HOST_NOT_INSTALLED from HOST_CRASHED from TRANSIENT_DISCONNECT — unit-tested with error string fixtures from real Chrome versions
- [ ] **Handshake:** Exponential backoff with circuit breaker — verify by unit-testing with a mocked port that disconnects immediately 5 times
- [ ] **Handshake:** Extension auto-detects install completion without manual reload — E2E verified
- [ ] **Handshake:** `allowed_origins` contains Chrome Web Store + Edge Add-ons Store IDs, not dev sideload ID — CI gate
- [ ] **Test audit:** `buildFullMIME` tested with UTF-8 subjects, long subjects, multipart boundary collisions, attachment filenames with spaces and UTF-8
- [ ] **Test audit:** Gmail HTTP client tested with real error response bodies (401, 403, 429, 5xx) from Gmail API docs
- [ ] **Test audit:** Goroutine lifecycle on shutdown tested — no abandoned drafts on `handleCreateDraft` mid-flight
- [ ] **Test audit:** C++ DLL message conversion tested with Unicode recipients, non-ASCII subjects, edge-case MAPI address formats
- [ ] **Race detector:** All known races from CONCERNS.md fixed before `-race` enabled in CI — verify `-race` is clean on the commit that enables the job
- [ ] **Race detector:** Windows `-race` job runs separately from main test job so it doesn't block fast PR feedback
- [ ] **E2E:** Happy-path test uses mocked Gmail (httptest), not real API
- [ ] **E2E:** No `waitForTimeout(N)` calls — only condition-based waits
- [ ] **E2E:** Runs headed with Xvfb on Linux, or on Windows runners directly
- [ ] **CI:** Windows smoke test actually runs the installer, doesn't just build it

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Shipped installer that doesn't register Edge manifest | LOW | Release a patch installer; extension can detect and prompt; no data loss |
| SmartScreen blocks installer, users can't install | MEDIUM | Publish pre-install guide with screenshots; apply to SignPath Foundation; fallback: ask first N beta users to "Run anyway" to build reputation |
| Race detector fires in CI and blocks all PRs | LOW-MEDIUM | Disable `-race` job temporarily; fix races in a dedicated branch; re-enable once clean |
| `buildFullMIME` has UTF-8 bug affecting non-English users | HIGH (already-sent drafts are corrupted) | Patch release; notify affected users; Gmail drafts can be edited manually but it's awful UX |
| Uninstaller doesn't clean HKLM\SOFTWARE\Clients\Mail\go-mapi | LOW | Ship a "cleanup.exe" standalone tool; document manual regedit steps in README |
| Native host crash loop amplified by linear backoff | MEDIUM | Kill the host process manually; patch release with exponential backoff + circuit breaker; warn users who hit it |
| DLL locked on uninstall, orphan files remain | LOW | Document reboot-then-retry; add clean-up to reinstall flow |
| E2E tests are flaky and ignored | MEDIUM | Delete the flaky tests (not just skip); replace with smaller deterministic unit tests until a reliable E2E can be written |
| Extension ID changes between dev and Chrome Web Store version | LOW-MEDIUM | Emergency manifest update to `com.gomapi.host.json` allowed_origins; push to users via installer update |
| Chrome native messaging API semantics drift between Chrome versions | MEDIUM | Log unknown `lastError` messages; add new mappings to error-state heuristic; keep a known-Chrome-versions test matrix |

---

## Pitfall-to-Phase Mapping

Assumes roadmap phases roughly follow: **Phase A: Installer foundation** → **Phase B: Signing & distribution** → **Phase C: Extension handshake UX** → **Phase D: Test audit & gap filling** → **Phase E: Race detector rollout** → **Phase F: E2E tests** → **Phase G: Release polish**.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| 1.1 UAC context swap | A | Install on VM as non-admin user; registry keys in correct SID hive |
| 1.2 Uninstall leaves MAPI handler | A | Automated install/uninstall smoke test on CI checks all 5 registry trees |
| 1.3 DLL locked during uninstall | A | Manual test with a long-running MAPI consumer loaded; document reboot path |
| 2.1 SmartScreen zero reputation | B | SignPath Foundation application submitted early; fallback guide ready |
| 2.2 AV false positive | B | VirusTotal scan each release; report false positives to vendors |
| 3.1 Only Chrome registered | A | CI installs on Windows, launches Chrome + Edge, verifies handshake for both |
| 3.2 32/64-bit registry view | A | Installer built as 64-bit; CI verifies with `reg query /reg:64` and `/reg:32` |
| 3.3 allowed_origins mismatch | A & C | CI gate diffs `manifest.json` extension ID against `com.gomapi.host.json` allowed_origins |
| 3.4 Manifest path encoding | A | CI includes at least one non-English Windows runner / VM |
| 4.1 Can't distinguish error modes | C | Unit tests for error-string → state mapping with real Chrome error fixtures |
| 4.2 Auto-detect install completion | C | E2E test covers the transition; chrome.alarms polling under 10s |
| 4.3 Crash-loop amplification | C | Unit test reconnect state machine with failing-port mock; circuit breaker after 5 attempts |
| 5.1 Coverage % trap | D | Gap list ranked by blast radius produced before any tests written |
| 5.2 buildFullMIME ASCII-only tests | D | Test matrix covers UTF-8, long subjects, multipart boundaries, attachment edge cases |
| 5.3 Shallow Gmail HTTP client mocks | D | Tests use real Gmail API error body fixtures; distinguish 401/403/429/5xx |
| 5.4 Hand-written Chrome mocks | D & F | Pure business logic with DI; integration coverage via Playwright (phase F) |
| 6.1 -race exposes existing races | E | Race fixes landed before the `-race` CI job is added |
| 6.2 -race Windows CI slowdown | E | Race job separate from main test job; Linux for PR, Windows nightly |
| 7.1 Playwright headless failure | F | Config uses `headless: false`; Linux CI runs under Xvfb or moves to Windows runner |
| 7.2 E2E depends on real Gmail | F | Architecture decision: mocked Gmail httptest for E2E, nightly real-API smoke |
| 7.3 E2E fixed-timeout flakes | F | Code review rejects any `waitForTimeout`; use `expect.poll` |
| 8.1 CI builds but doesn't verify on Windows | A-G (all phases) | CI has a `windows-latest` smoke job on every PR to main |

---

## Sources

**Chrome native messaging:**
- [Chrome for Developers — Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) (HIGH — authoritative)
- [Microsoft Learn — Native messaging in Edge](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/native-messaging) (HIGH)
- [browserpass-native Registration docs on DeepWiki](https://deepwiki.com/browserpass/browserpass-native/5.3-native-messaging-host-registration) (MEDIUM — community-maintained, cross-browser table)
- [Chrome for Developers service worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle) (HIGH)
- [anthropics/claude-code issue #16350 — Native host dies when SW idle](https://github.com/anthropics/claude-code/issues/16350) (MEDIUM — real-world bug report)
- [anthropics/claude-code issue #24367 — Edge native messaging not registered](https://github.com/anthropics/claude-code/issues/24367) (MEDIUM)
- [GoogleChrome/developer.chrome.com issue #2688 — connectNative SW lifetime claim](https://github.com/GoogleChrome/developer.chrome.com/issues/2688) (HIGH)
- [chromium-extensions group — "Specified native messaging host not found"](https://groups.google.com/a/chromium.org/g/chromium-extensions/c/fODe9JMz8iw) (MEDIUM)

**Installer / Inno Setup / WiX:**
- [Inno Setup Registry section docs](https://jrsoftware.org/ishelp/topic_registrysection.htm) (HIGH)
- [codestudy.net — Inno Setup PrivilegesRequired=none](https://www.codestudy.net/blog/make-inno-setup-installer-request-privileges-elevation-only-when-needed/) (MEDIUM)
- [w3tutorials.net — Installing for current user from elevated installer](https://www.w3tutorials.net/blog/installing-application-for-currently-logged-in-user-from-inno-setup-installer-running-as-administrator/) (MEDIUM)
- [Rubberduck issue #458 — HKCU wrong profile](https://github.com/rubberduck-vba/Rubberduck/issues/458) (MEDIUM — post-mortem)
- [WiX vs Inno Setup 2026 comparison](https://appmus.com/vs/wix-vs-inno-setup) (MEDIUM)

**Code signing / SmartScreen:**
- [SignPath Foundation terms for OSS](https://signpath.org/terms.html) (HIGH — authoritative)
- [SignPath DevSec360 for Open Source](https://signpath.io/solutions/open-source-community) (HIGH)
- [SignPath docs — GitHub integration](https://docs.signpath.io/trusted-build-systems/github) (HIGH)
- [Microsoft Tech Community — Trusted Signing for individuals](https://techcommunity.microsoft.com/blog/microsoft-security-blog/trusted-signing-is-now-open-for-individual-developers-to-sign-up-in-public-previ/4273554) (HIGH)
- [Azure Trusted Signing FAQ](https://learn.microsoft.com/en-us/azure/artifact-signing/faq) (HIGH)
- [DigiCert — SmartScreen and Application Reputation](https://www.digicert.com/blog/ms-smartscreen-application-reputation) (HIGH)
- [Gravitational Teleport issue #15995 — SmartScreen blocking Connect installer](https://github.com/gravitational/teleport/issues/15995) (MEDIUM — post-mortem)
- [mintty/wsltty issue #32 — SmartScreen](https://github.com/mintty/wsltty/issues/32) (MEDIUM)
- [treeverse/dvc issue #5192 — Unknown publisher SmartScreen](https://github.com/treeverse/dvc/issues/5192) (MEDIUM)

**Testing / coverage / race detector:**
- [Codecov — Mutation testing vs coverage](https://about.codecov.io/blog/mutation-testing-how-to-ensure-code-coverage-isnt-a-vanity-metric/) (HIGH)
- [Trail of Bits — Mutation testing](https://blog.trailofbits.com/2025/09/18/use-mutation-testing-to-find-the-bugs-your-tests-dont-catch/) (HIGH)
- [Bitfield Consulting — Slow, flaky, failing Go tests](https://bitfieldconsulting.com/posts/slow-flaky-failing) (HIGH)
- [Tailscale flakytest package](https://pkg.go.dev/tailscale.com/cmd/testwrapper/flakytest) (MEDIUM)
- [InfluxData — Reproducing a flaky Go test](https://www.influxdata.com/blog/reproducing-a-flaky-test-in-go/) (MEDIUM)
- [Mark Phelps — Testing API clients in Go](https://markphelps.me/posts/testing-api-clients-in-go/) (MEDIUM)
- [Stellar Go httptest package](https://pkg.go.dev/github.com/stellar/go/support/http/httptest) (MEDIUM)
- [sebdah/goldie golden file testing](https://github.com/sebdah/goldie) (HIGH)
- [Go runtime — race detector overhead](https://go.dev/doc/articles/race_detector) (HIGH)

**CI / Windows runners:**
- [actions/runner-images issue #7320 — Windows runners slow](https://github.com/actions/runner-images/issues/7320) (HIGH — official)
- [chadgolden.com — GitHub Actions hosted Windows runners slower than expected](https://chadgolden.com/blog/github-actions-hosted-windows-runners-slower-than-expected-ci-and-you) (MEDIUM)
- [actions/runner-images issue #12647 — Windows-2025 slower post D: drive removal](https://github.com/actions/runner-images/issues/12647) (HIGH)

**Playwright / extension E2E:**
- [DEV Community — E2E tests for Chrome extensions using Playwright and CDP](https://dev.to/corrupt952/how-i-built-e2e-tests-for-chrome-extensions-using-playwright-and-cdp-11fl) (MEDIUM)
- [kelseyaubrecht/playwright-chrome-extension-testing-template](https://github.com/kelseyaubrecht/playwright-chrome-extension-testing-template) (MEDIUM)
- [Playwright docs](https://playwright.dev/docs/intro) (HIGH)

**GitHub releases / download URLs:**
- [GitHub community discussion #46420 — Release download URL redirecting](https://github.com/orgs/community/discussions/46420) (MEDIUM)
- [codestudy.net — Direct download URL for latest release](https://www.codestudy.net/blog/github-url-for-latest-release-of-the-download-file/) (MEDIUM)

**MIME / Gmail API:**
- [Google Workspace Gmail API — Create and send messages](https://developers.google.com/workspace/gmail/api/guides/sending) (HIGH)
- [Gmail API v1 messages reference](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages) (HIGH)

**C++ / MinGW / testing:**
- [Google Test CMake quickstart](https://google.github.io/googletest/quickstart-cmake.html) (HIGH)
- [google/googletest issue #2418 — MinGW CMake build difficulty](https://github.com/google/googletest/issues/2418) (MEDIUM)

---

*Pitfalls research for: go-mapi v2.0.0 installer + handshake + test completeness*
*Researched: 2026-04-10*
