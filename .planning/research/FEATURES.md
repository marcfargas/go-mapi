# Feature Research

**Domain:** Windows native-host installer UX paired with a browser extension (go-mapi v2.0.0)
**Researched:** 2026-04-10
**Confidence:** MEDIUM-HIGH

Scope: What install, detection, recovery, and uninstall features modern browser-extension-paired native host apps ship. Comparable products studied: 1Password desktop + extension, Bitwarden desktop + extension, KeePassXC-Browser, Dashlane, Authy, Brave Wallet, MetaMask, Plasmo native messaging examples, Proton Pass, JabRef browser extension. Hard constraint: go-mapi is FOSS, privacy-first, solo-maintained, Windows-only, and will ship either SignPath-signed or unsigned.

The recurring lesson from competitor post-mortems (Bitwarden, KeePassXC, JabRef) is the same: **native messaging silently fails and the error the user sees is nearly useless** ("Specified native messaging host not found" / "Key exchange was not successful" / "Awaiting confirmation from desktop" forever). Every table-stakes feature below exists because of a real support thread where a non-technical user got stuck.

---

## Feature Landscape

### Bucket 1 — First-install detection in the extension popup

**Table stakes**

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Detect "host missing" vs "host disconnected" vs "host crashed" and distinguish them | Users conflate "not installed" with "broken". If popup says "disconnected" to someone who never installed anything, they uninstall the extension. `chrome.runtime.connectNative()` fires `onDisconnect` with `chrome.runtime.lastError.message = "Specified native messaging host not found."` when the manifest/registry key is missing — that's the signal for "not installed". | LOW | Match the exact error string. Everything else is a real disconnect. Visible to user. Not blocked by signing. |
| "Install go-mapi helper" call-to-action in the popup when host is missing | Without it, the popup just looks broken. This is where 1Password's "desktop app required" and KeePassXC's troubleshooting-guide-as-UX fail — they dump users in a docs page. | LOW | Single primary button, no wall of text. Visible. Not blocked by signing. |
| Direct download link to a stable URL (not a GitHub release page) | Non-technical users get lost on GitHub. A stable URL like `https://go-mapi.../download/latest` that 302s to the current installer means the extension never has to be updated to point at new releases. | LOW | Already in PROJECT.md. Stable URL is an ops concern. Visible. Not blocked by signing. |
| Show the installer's SHA-256 next to the download link | Security-minded users (the FOSS crowd that's most likely to try an unsigned MAPI-intercepting DLL) want to verify. Costs nothing to display. | LOW | Pull from a sidecar `.sha256` file on the same host. Visible. Not blocked by signing. |
| Human-readable version string in the popup ("go-mapi helper v2.0.0 not installed") | Users need to know *which* thing is missing, especially when troubleshooting with the maintainer. | LOW | Read from extension manifest. Visible. |

**Differentiators**

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Pre-install preview in popup: "After install, emails from legacy apps will appear here" with an empty-state illustration | Reduces the "what does this even do?" bounce before the user commits to the install. | LOW | Pure UI. Visible. |
| Auto-polling for host availability after user clicks "Install" (every 2s for ~2min) so the extension reconnects without the user reopening the popup | Bitwarden and Claude-in-Chrome both have open GitHub issues where users have to manually click "reconnect" or restart the browser — major friction point. Solving this is where go-mapi can visibly beat incumbents. | MEDIUM | Already half-implemented (service worker has 6s reconnect alarm). Extend: escalate polling rate after an explicit "install in progress" signal from popup, decay back to 6s afterward. Invisible plumbing / visible outcome. |
| Version mismatch detection ("host v1.9, extension v2.0 — please update helper") | Happens whenever the user upgrades the extension via Chrome Web Store but doesn't re-run the installer. Without this feature it looks like a generic breakage. | LOW-MEDIUM | Requires a version field in the `READY` native message (probably already exists in protocol, verify). Visible. |

**Anti-features (do NOT build)**

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Telemetry-based install analytics ("88% of users completed install") | Product managers love it. | Violates go-mapi's privacy baseline. No retention, no network calls outside Gmail API. | Count nothing. Rely on GitHub issues + personal usage for signal. |
| Remote feature flags to A/B-test the install copy | Lets you iterate copy without a re-release. | Requires a server, phones home, defeats the FOSS ethos. | Iterate via extension releases like normal. |
| "Share your install experience" prompt | Competitors use it for NPS. | Survey fatigue + privacy leak + adds a maintenance burden Marc doesn't want as a solo dev. | Don't ask. |

---

### Bucket 2 — Download and launch

**Table stakes**

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| SmartScreen guidance shown *before* the user downloads, not after they're stuck on the warning | Windows 11 24H2/25H2 tightened SmartScreen — unsigned binaries need ~15k clean downloads to build reputation, which a FOSS project will never reach organically. Users hit "Windows protected your PC" and abandon. Telling them what to expect beforehand ("you'll see a blue warning, click 'More info' then 'Run anyway'") keeps them moving. | LOW | Short 3-screenshot inline guide in the popup or on the download landing page. If signed via SignPath this shrinks but doesn't disappear (reputation still takes time). Visible. Mitigated, not removed, by signing. |
| UAC elevation handled cleanly (single prompt, clearly branded) | HKLM registry writes require admin. Users panic when they see repeated UAC prompts or an unbranded "Unknown publisher" dialog. | LOW-MEDIUM | Inno Setup / NSIS both handle this with a manifest. If signed, publisher name appears in the UAC dialog — worth chasing SignPath for this reason alone. Visible. Partially blocked by signing (publisher name in UAC). |
| Installer is a single file, small (<10 MB) | Large installers feel enterprisey and untrustworthy for a "simple bridge". NSIS overhead is ~34 KB, Inno Setup ~200–300 KB — both fine. | LOW | Tooling decision, see STACK.md for recommendation. Not blocked by signing. |
| Download progress feedback on the hosting site | If the download stalls or the file is 20 MB, the user needs feedback. Browser download shelf handles this natively — the feature is "don't break it" (don't redirect through a tracker, don't interstitial). | LOW | Serve the `.exe` with correct `Content-Length`. Not blocked by signing. |

**Differentiators**

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Per-user install (HKCU) as the default, HKLM only if explicitly chosen | Chrome's native messaging docs explicitly recommend HKCU to avoid admin prompts entirely. Skips UAC for the common case. Downside: doesn't cover all Windows accounts on a shared machine, which for a solo user isn't a problem. | MEDIUM | **Non-trivial for go-mapi specifically** because the MAPI DLL registration under `HKLM:\SOFTWARE\Clients\Mail\go-mapi` is HKLM-only per Windows convention. Need to verify whether MAPI registration works from HKCU on modern Windows. Differentiator only if it eliminates UAC, otherwise drop. Visible (no UAC = huge win). |
| SignPath.io-signed installer | SignPath Foundation provides free signing for OSS projects meeting specific criteria (OSI license, verifiable build, manual release approval). LGPL-3.0 qualifies. Removes "Unknown publisher" in UAC, softens (not eliminates) SmartScreen. | MEDIUM | Integration work: reproducible build, submission process, manual release approval each version. Already in PROJECT.md Active list. Invisible plumbing / visible outcome (no scary dialogs). |

**Anti-features**

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Downloader stub that fetches the real installer | Feels modern (Chrome installer works this way). | Adds a second network round-trip, looks more suspicious to AV (two-stage = malware pattern), breaks offline install, doubles SmartScreen friction. | Ship one `.exe` that contains everything. |
| Web-based installer that runs in the browser | Very slick demos. | Browsers can't elevate, can't write to HKLM, can't install DLLs. Would require a dance with a separate helper. Not worth it. | Normal desktop installer. |
| In-extension "sideload this DLL for me" via a hypothetical browser API | Zero such API exists in Chrome/Edge and won't in 2026. | Fantasy feature. | Normal installer. |

---

### Bucket 3 — Installer actions

**Table stakes**

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Copy C++ DLL to a stable path | The existing `scripts/install.ps1` does this already. Installer just needs to match. | LOW | `%ProgramFiles%\go-mapi\` for HKLM install, `%LOCALAPPDATA%\Programs\go-mapi\` for HKCU. Invisible. |
| Copy Go native host binary to a stable path | Same. | LOW | Same locations as above. Invisible. |
| Write MAPI registry keys (`HKLM:\SOFTWARE\Clients\Mail\go-mapi`) | Without this, Windows apps never call the DLL. This is the core function of install. | LOW-MEDIUM | Must match v1.0.0's PowerShell script exactly, otherwise MAPI routing breaks. Read `scripts/install.ps1` before authoring. Invisible. |
| Write Chrome/Edge native messaging manifest to the correct location | Without this, `connectNative()` fails. The manifest JSON must point at the absolute path of the Go binary and whitelist the extension ID. | LOW | Chrome docs: `HKCU\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host` default value = full path to manifest JSON. Same for Edge under `Microsoft\Edge`. Invisible. |
| Write to BOTH Chrome and Edge manifest locations | Chromium-family browsers don't share the native messaging host registry. Edge users get silently broken if you only do Chrome. | LOW | Two registry keys, same manifest JSON. Invisible. |
| "go-mapi" entry in Control Panel → Programs and Features (Add/Remove Programs) | Windows convention. If it's not there, non-technical users can't uninstall and lose trust. Also what AV tools inspect. | LOW | Inno Setup and NSIS do this automatically from their uninstaller. Visible (in Control Panel). |
| Start Menu shortcut pointing to... a readme or status page | Windows users look for installed apps in Start Menu. A missing Start Menu entry feels like a half-install even though go-mapi has no GUI. | LOW | Point at a local HTML status page or the extension icon instructions. Visible. |
| Installer version is the same as extension version (both v2.0.0) | Without version parity, debugging mismatches becomes impossible. | LOW | CI enforces. Invisible. |

**Differentiators**

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Installer writes a `version.txt` next to the Go binary that the host reads and reports in the `READY` native message | Lets the extension show a precise "helper v2.0.0" in the popup, detect version skew, and surface "please update" when the extension gets upgraded via Chrome Web Store without re-running the installer. | LOW | Small plumbing, high diagnostic value. Invisible plumbing / visible version strings. |
| Installer detects existing v1.0.0 PowerShell-based install and offers to clean it up | v1.0.0 developers may have the registry keys and DLL from `install.ps1`. A fresh installer over the top without cleanup could leave stale paths. | MEDIUM | Only matters for the small v1.0.0 user base (Marc + a handful). Could be deferred if audit shows it's nearly nobody. Visible. |
| Installer is idempotent: re-running it over an existing install upgrades in place | Users will re-run the installer for updates (host auto-update is explicitly out of scope in PROJECT.md). It must not leave the system in a half-state. | LOW-MEDIUM | Inno Setup does this by default; NSIS needs explicit scripting. Visible (it "just works"). |

**Anti-features**

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Auto-start tray icon / background service | "Always-on" feels enterprise-ready. | The Go host is started on demand by Chrome via native messaging — that's the whole point. A tray icon adds memory, a process to manage, an auto-start registry entry, and nothing useful. 1Password, Bitwarden have tray icons *because they are standalone vaults*. go-mapi has no standalone function. | No tray, no service, no autostart. Host runs when Chrome connects. |
| Windows Service registration | "Enterprise software runs as a service." | Would run the Go host without a browser connection and serve... nothing. Waste of a process slot. | No service. |
| Desktop shortcut | Users can't interact with a native-messaging host directly. | Clicking the shortcut would do nothing useful (or worse, launch the binary which expects stdin/stdout framing). | Start Menu entry only, and it points at docs/status. |
| Firewall rule | "Good installers punch their own holes." | The Go host only talks to `googleapis.com` over the normal outbound HTTPS path — no inbound, no custom port. No firewall rule needed. Adding one widens the attack surface and requires admin. | None. |
| Telemetry opt-in dialog during install | "Product teams need metrics." | Same privacy baseline as bucket 1. | None. |
| Browser launch after install | Many installers do this ("open your browser to finish setup"). | The extension is *already* open in most cases (that's how the user got to the download link). Re-launching steals focus and feels spammy. | Trust the extension's auto-detect to surface the success toast. |
| "Install for all users" toggle | MSI tradition. | HKLM MAPI registration is already a constraint. Adding an explicit toggle doubles the test matrix for a solo dev. | One install mode. Pick HKCU or HKLM based on MAPI investigation, commit. |

---

### Bucket 4 — Post-install handshake

**Table stakes**

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Extension auto-reconnects to host without user action once the native messaging manifest + registry key appear | This is the "magic moment" that makes the install feel seamless. Without it, the user has to click the extension icon / reload / restart the browser — competitors like Bitwarden, Claude-in-Chrome get bug reports every week about this. | MEDIUM | Service worker already has a 6s reconnect alarm. Need to: (a) detect "installer launched" state and accelerate polling, (b) gate on explicit `READY` message, not just port open, to avoid showing success before the host is actually healthy. Partially existing. |
| Success toast / notification after handshake completes | Explicit confirmation that the install worked. Without it, users don't know whether to close the installer, reload the browser, or give up. | LOW | Use `chrome.notifications` API (already in use for drafts). Visible. |
| Popup state transitions from "not installed" → "installing..." → "connected" with clear labels | Progress visibility. Users who don't see state changes assume it's broken. | LOW | Pure UI state machine. Visible. |
| If handshake doesn't complete within ~2 min after the "Install" button click, show a "Still not connected?" recovery flow | Catches the ~5% of users where install silently failed, AV ate the DLL, or they cancelled UAC. Without a timeout, they sit staring at a spinner. | MEDIUM | Links into bucket 5 error recovery. Visible. |

**Differentiators**

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Handshake includes a roundtrip test ("extension sends PING, host echoes PONG") before reporting success | Detects partial installs where the manifest points at a binary that exists but is broken (e.g., wrong architecture, missing dependency, AV quarantined). | LOW | Tiny protocol addition. Invisible plumbing, visible as a more accurate success state. |
| Handshake surfaces host-reported environment info (Windows version, Chrome version, host version) to popup's about/debug pane | Users filing GitHub issues can screenshot this instead of typing it wrong. Saves maintainer time. | LOW | Add one native message type. Visible in about pane. |

**Anti-features**

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Celebration modal with confetti | "Feels rewarding." | Spammy, steals focus, delays the user getting back to work. | Quiet success toast + popup state change. |
| "Rate go-mapi on the Chrome Web Store" prompt after install | Standard extension monetization pattern. | Marc is a solo maintainer not optimizing for Chrome Web Store ranking. Annoying to users. | Don't prompt. |
| Walkthrough / guided tour of the popup | Onboarding SaaS playbook. | The popup has ~4 features (list, detail, save draft, delete). A tour adds modal dismissals for zero information. | Empty-state illustration when queue is empty. |

---

### Bucket 5 — Error recovery

**Table stakes**

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Installer writes a log file (`%LOCALAPPDATA%\go-mapi\install.log`) with every step's success/failure | Without a log, every install failure is unreproducible. Both Inno Setup and NSIS have built-in logging. | LOW | Turn it on, ship it. Invisible unless user needs it. |
| "Still not connected?" recovery screen in popup with 3 specific troubleshooting bullets and a link to the log file | This is the failover path for the ~5% who hit a problem. Competitors link to a 40-item troubleshooting wiki (KeePassXC) and users bail. | LOW-MEDIUM | Keep bullets *specific*: "AV may have quarantined the DLL", "UAC cancelled", "Chrome was not running at install time". Not a generic docs dump. Visible. |
| Installer detects admin-required operations and exits gracefully if UAC was declined (not a half-install) | NSIS/Inno Setup default behavior, but has to be *tested*. A half-install that partially wrote some registry keys is the worst outcome. | LOW | Transaction-like: either all registry keys + files land, or none do. Test with deliberate UAC decline. Invisible. |
| Installer detects AV interference (file couldn't be written / was deleted mid-install) and surfaces a clear message | AV false-positives on unsigned DLLs that intercept MAPI are near-certain. | MEDIUM | Try/catch around file copy, check file exists post-copy. Surface "Your antivirus blocked go-mapi.dll. Add an exclusion for `%ProgramFiles%\go-mapi\` or download from [source URL]." Visible. Mitigated by signing. |
| Diagnostic command in the popup ("Copy diagnostic info") that dumps: host version, extension version, manifest file existence, registry key presence, install log path | Enables async support via GitHub issues. Non-technical users can paste this into an issue. | MEDIUM | Requires host → extension to report filesystem state. Visible. |

**Differentiators**

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Installer pre-flight check: verify it can write to the target directories *before* writing anything | Avoids half-installs. Tells the user about AV / permission issues before touching the system. | MEDIUM | Inno Setup supports `[Code]` pre-install functions. Invisible plumbing, visible when it catches a problem. |
| Corporate-lock detection ("This machine is managed by Group Policy — go-mapi may be blocked from writing MAPI registry keys") | A non-trivial chunk of Windows users are on domain-joined machines where HKLM writes are blocked. Detecting this and saying so up front is rare and appreciated. | MEDIUM-HIGH | Detect via Group Policy API or by probing the registry key before writing. Edge case — defer unless enterprise users actually request it. Visible. |

**Anti-features**

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Automatic crash reporter that uploads stack traces | Modern desktop app standard. | Privacy violation: would upload email-adjacent stack data without consent. No server to receive them anyway. | Local log file + manual diagnostic copy button. |
| In-app "request help" form that sends a message to Marc | Friendly. | Requires an inbox + a server + support capacity Marc doesn't have as a solo dev. | GitHub issues link. |
| AV-bypass "trusted installer" trick to suppress SmartScreen | Users would thank you. | Exactly the technique real malware uses — would flag go-mapi as *more* suspicious. | Honest pre-download SmartScreen guidance + SignPath. |
| Auto-retry install on failure with different parameters | Feels smart. | Masks the root cause, risks making a half-install worse, can loop. | Clear failure message + log file, user decides. |

---

### Bucket 6 — Uninstall

**Table stakes**

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Uninstall entry in Control Panel → Programs and Features | Windows convention. Must exist. | LOW | Both Inno Setup and NSIS do this automatically. Visible. |
| Uninstaller removes: DLL, Go host binary, MAPI registry keys, Chrome/Edge native messaging manifests + registry keys, Start Menu shortcut, install log | Partial uninstalls are worse than no uninstall — users think the app is gone, browsers keep trying to connect. | LOW-MEDIUM | Inno Setup `[UninstallDelete]` handles files; explicit registry cleanup needed for MAPI + native messaging keys. Test: after uninstall, the popup must show "not installed" state, not "disconnected". Invisible plumbing, visible via clean state. |
| Uninstaller cleans up `%TEMP%\go-mapi\` (JSON files, error folder, `native-host.log`) | Delete-on-process privacy model means this *should* be empty, but orphaned files exist (crashes, AV-quarantined files, files written but never processed). Leaving them behind is a privacy leak. | LOW | Simple directory removal. Invisible. |
| Uninstaller does NOT touch the Chrome extension | Uninstalling the browser extension is Chrome's job. Touching it would require scary permissions. | LOW | Explicit non-action. User uninstalls the extension separately via Chrome. Invisible. |
| Uninstaller does NOT touch OAuth tokens | `chrome.identity` tokens are owned by Chrome/the extension, not by the host. The host never stores them. There is nothing for the uninstaller to clean. | LOW | Verify from code: confirm no token ever hits disk on the Go side. Part of the testing audit. Invisible. |

**Differentiators**

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Uninstaller shows a final "Everything removed. The Chrome extension was not removed — to fully uninstall, remove it from Chrome as well" message with a link | Honest about what it did and didn't do. Saves a support thread. | LOW | Inno Setup `[Messages]` supports this. Visible. |
| Post-uninstall verification screen ("Checked: no DLL, no registry keys, no temp files remain") | Proves the privacy claim. Matches the FOSS audience's expectations. | LOW | Optional pane. Visible. |

**Anti-features**

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| "Why are you uninstalling?" survey | Standard consumer app retention tactic. | No server to collect responses, no retention to improve, hostile exit. | Nothing. |
| "Keep go-mapi running in case you change your mind" leave-behind service | Some AV tools do this. | Widely hated and exactly the opposite of privacy-first. | Full removal. |
| Uninstaller preserves user data "in case of reinstall" | Defensible for apps with user-created documents. | go-mapi has no user documents — just transient email JSON that should be gone anyway. Preserving it is a leak. | Full removal. |

---

### Bucket 7 — Test-suite completeness

The PROJECT.md is explicit: risk-based gap filling, not a coverage %. These features define what "a trustworthy test suite" looks like for this specific three-language, filesystem-IPC, browser-extension project.

**Table stakes**

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| `go test -race` in CI on the native host package | Watcher + debouncer + in-memory email map + connection lifecycle = classic goroutine concurrency. Without `-race` in CI, data races hide until production. Already in PROJECT.md Active list. | LOW | Single CI flag. Invisible. Critical. |
| Direct unit tests for `buildFullMIME()` in `gmail.go` | TESTING.md flagged this as untested except via fixtures. MIME construction is a known minefield (CRLF, header folding, base64 boundaries, attachment Content-Type) and bugs ship silent. | LOW-MEDIUM | Fixture-driven table tests with golden MIME outputs. Invisible. |
| HTTP mocking for the Gmail API client | Currently no tests. Network code without tests = the first thing that breaks in a new Go version, new Gmail API response shape, or new error path. | LOW | Go stdlib `httptest.NewServer` + fixture responses. Invisible. |
| C++ DLL smoke tests (message conversion round-trip, at minimum) | Zero tests today per PROJECT.md. `ConvertAnsiMessage` and `ConvertWideMessage` are high-blast-radius: they're the entry point from untrusted Windows app data. | MEDIUM | CMake + CTest + a tiny harness that feeds in fake `MapiMessage` structs and validates the JSON output. Not full coverage — just the conversion functions. Invisible. |
| Playwright E2E happy-path test: MAPI call → JSON file → queue → Gmail draft | Regression safety on the main flow is the one test that catches integration breakage. PROJECT.md scopes it to happy path only. | HIGH | Headed mode in CI with Xvfb (Playwright + Chrome extensions don't support headless). Mock Gmail API endpoint. Fake MAPI call by writing JSON directly to `%TEMP%\go-mapi\` (the DLL doesn't need to be exercised for the main flow test). Invisible. See PITFALLS.md for flakiness hazards. |
| Protocol fixtures shared between Go and TypeScript stay in sync | Already exists per PROJECT.md. Feature is "don't break it": CI fails if Go and TS generate divergent parses of the same fixture. | LOW | Existing. Keep a CI check that exercises both. Invisible. |
| Test fixtures committed under `src/native-host/testdata/` with realistic (anonymized) MAPI output | Fixture rot is the #1 silent killer of fixture-based tests. Real-world MAPI outputs have edge cases that hand-written JSON won't. | LOW | Capture fixtures via a one-time real MAPI call, scrub PII, commit. Invisible. |
| CI signal quality: every test failure must be reproducible from a single CI log line | Flaky tests erode trust fast for a solo maintainer. | MEDIUM | Structured logging in tests, Playwright `--trace on-first-retry`, Go test `-v` output. Invisible. |

**Differentiators**

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Installer smoke test in CI (install on a clean Windows runner, verify DLL + registry + manifest land in expected places, run uninstaller, verify clean state) | The most blast-radius-expensive bug in v2.0.0 is "installer corrupts a user's machine". One CI job that runs the installer and checks results pays for itself immediately. | HIGH | GitHub Actions `windows-latest` runner. Write a test harness that runs the installer with `/SILENT` + `/LOG`, asserts filesystem/registry state, runs the uninstaller, asserts removal. Invisible. |
| Protocol version compatibility test: host v2.0.0 against extension v1.0.0 and vice versa | Catches version-skew bugs before release. | LOW-MEDIUM | Store old protocol fixtures + run both new and old against them. Invisible. |
| Trace artifacts uploaded on every failure (Playwright traces + Go `-race` output + installer log) | Solo maintainer can't reproduce a flake on first try without them. | LOW | GitHub Actions `actions/upload-artifact` on failure. Invisible. |
| Mutation testing on `buildFullMIME()` and `validateMailMessage()` | Line coverage is gameable; mutation testing is not. Applied narrowly to the two highest-risk functions, it validates the test suite *itself*. | MEDIUM | `go-mutesting` or similar. Scoped to two files only. Invisible. Optional — if effort is too high, skip and rely on code review. |

**Anti-features**

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| 80% line coverage target (or any % target) | Managers love it, CI loves enforcing it. | Explicitly rejected in PROJECT.md. Coverage % is gameable, penalizes deleted-dead-code, rewards cargo-cult tests. | Risk-based gap list, reviewed per-phase. |
| Full end-to-end Gmail integration test against real Gmail API in CI | Maximum realism. | Rate limits, flaky external service, would require secrets in CI, creates drafts in a real mailbox. | Mock the Gmail API; run the real-API smoke test manually before releases. |
| Snapshot-testing the React popup | React community default. | React Bootstrap markup churns; snapshots drift; they catch style changes, not behavior. | Write behavior tests (click X, expect Y state) where behavior matters. Skip pure render tests. |
| Load tests on the watcher | Performance engineering hygiene. | go-mapi's real-world load is 0–10 emails/day/user. Load tests optimize for scenarios that never happen. | A single "handles 1000 files in the queue without crashing" test is enough. |
| E2E tests for every Chrome-version permutation | Defensive matrix testing. | Each matrix cell is a slow flaky E2E run. Chrome releases every 4 weeks. Matrix explodes. | Latest stable Chrome + latest stable Edge. Trust Chromium compatibility. |
| Flaky test retry policy ("retry failing tests 3x") | Common "fix" for flakes. | Hides flake sources; flakes *are* the bug. | Trace every failure, fix the flake or mark the test skipped with a TODO. |

---

## Feature Dependencies

```
[Install button in popup] ──requires──> [Host-missing detection via connectNative error string]

[Success toast] ──requires──> [Extension auto-reconnect after install]
                    └──requires──> [Accelerated post-install polling (2s for ~2min)]
                                        └──requires──> ["install in progress" state flag in service worker]

[Extension auto-reconnect] ──requires──> [Installer writes manifest + registry key atomically]
                                  └──requires──> [READY message from host confirming healthy state]

[PING/PONG handshake test] ──enhances──> [Success toast] (accuracy: detects partial installs)

[Version mismatch detection] ──requires──> [version.txt next to Go binary] OR [version in READY message]

["Still not connected?" recovery] ──requires──> [Install progress timeout (~2min)]
                                         └──enhances──> [Diagnostic copy button]

[Diagnostic copy button] ──requires──> [Host reports filesystem + registry state back to extension]

[Installer smoke test in CI] ──requires──> [Silent-install mode + log file]
                                    └──enhances──> [Uninstaller verification]

[Playwright E2E happy path] ──requires──> [Mock Gmail API endpoint]
                                  └──requires──> [Headed-mode CI with Xvfb]
                                  └──requires──> [Trace upload on failure]

[SignPath-signed installer] ──enhances──> [Pre-download SmartScreen guidance] (reduces friction)
                              └──enhances──> [UAC dialog clarity] (publisher name shown)

[HKCU install mode] ──conflicts──> [MAPI registry under HKLM] (must resolve via investigation)

[Uninstaller cleanup of %TEMP%\go-mapi\] ──enhances──> [Privacy claim]
                                         └──requires──> [No tests relying on leftover fixture files]
```

### Dependency notes

- **Install-button → missing-host detection:** The popup can't offer "Install" until it can distinguish *missing* from *disconnected*. This gates the entire install UX — it's the foundation feature.
- **Success toast → auto-reconnect → accelerated polling:** The "magic moment" is a three-step chain. All three must ship together or the experience feels broken (user installs, sees nothing change, reopens popup manually).
- **Diagnostic copy button → host-reported state:** Requires a new native message type. Worth doing even if the button UI is deferred, because it also unlocks the version-mismatch detection.
- **Installer CI smoke test → silent-install mode:** Requires choosing an installer tool (Inno Setup, NSIS) that supports silent mode with a log file. Both do.
- **HKCU install mode ⨯ HKLM MAPI:** Hard conflict. Must be resolved by investigation (does modern Windows accept MAPI registration under HKCU?). If no, then HKCU install mode is dropped and UAC is unavoidable.
- **Playwright E2E → headed-mode CI:** Chrome extensions don't load in Playwright headless. This forces Xvfb on Linux runners or Windows runner with display. Drives CI cost and flakiness profile.

---

## MVP Definition

### Launch with (v2.0.0)

Non-negotiable for the milestone to ship.

- [ ] **Host-missing detection** — distinguishes "not installed" from "disconnected" via `connectNative` error string. Gate for everything else.
- [ ] **Install button + stable direct-download URL** — popup shows a single-click path to the installer. Matches PROJECT.md active requirement.
- [ ] **Pre-download SmartScreen guidance** — 3-screenshot inline guide. Without this, unsigned-installer abandonment rate is too high.
- [ ] **Single-file installer** — Inno Setup or NSIS (see STACK.md), one `.exe`, small (<10 MB).
- [ ] **Installer actions**: DLL, Go host, MAPI registry, Chrome + Edge native messaging manifest, Start Menu entry, Control Panel uninstall entry. All must land or none (atomic).
- [ ] **Version.txt + READY message version field** — enables version-mismatch detection and diagnostics.
- [ ] **Accelerated post-install polling + success toast** — the "magic moment". Service worker gets a 2s-for-2min fast path.
- [ ] **"Still not connected?" recovery screen with 3 specific bullets + log file link** — failover path for the ~5% who hit problems.
- [ ] **Idempotent installer** — re-running upgrades in place. Users re-run to update.
- [ ] **Full uninstaller** — DLL, host binary, registry keys (MAPI + native messaging, Chrome + Edge), Start Menu, `%TEMP%\go-mapi\`. Control Panel entry.
- [ ] **`go test -race` in CI** — already in PROJECT.md active list.
- [ ] **`buildFullMIME` direct tests + Gmail HTTP client mocking** — TESTING.md gaps with highest blast radius.
- [ ] **Playwright E2E happy path** — single test, headed CI, mocked Gmail.
- [ ] **C++ DLL conversion smoke test** — one CTest harness for `ConvertAnsiMessage` / `ConvertWideMessage`.
- [ ] **SignPath.io application + signed release** — if SignPath accepts the project before release. If not, ship unsigned with the SmartScreen guidance as the mitigation (PROJECT.md accepts this fallback).

### Add after validation (v2.0.x / v2.1.x)

Only add if real usage shows the need.

- [ ] **Diagnostic copy button** — if GitHub issues show users struggle to report state accurately.
- [ ] **PING/PONG handshake test** — if the success toast ever fires on a partial install.
- [ ] **Installer CI smoke test** — highly desirable but high-effort; defer if Inno Setup install proves stable across manual testing.
- [ ] **v1.0.0 cleanup path** — only if v1.0.0 PowerShell-install users report conflicts.
- [ ] **HKCU install mode** — only if MAPI-under-HKCU investigation confirms feasibility AND users complain about UAC.
- [ ] **Mutation testing on high-risk files** — if post-release bugs land in `buildFullMIME` or `validateMailMessage`.

### Future consideration (v3+)

Deferred beyond v2.0.0.

- [ ] **Corporate-lock / Group Policy detection** — enterprise users aren't the v2.0.0 audience.
- [ ] **Host auto-update** — explicitly deferred in PROJECT.md.
- [ ] **Multi-browser support beyond Chrome/Edge** — Firefox uses a different native messaging convention; out of scope for v2.0.0.
- [ ] **Pre-install environment probing (AV detection, GPO detection)** — too much complexity for MVP.
- [ ] **Installer internationalization** — English only for v2.0.0.

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Host-missing detection (via error string) | HIGH | LOW | P1 |
| Install button + direct download URL | HIGH | LOW | P1 |
| Pre-download SmartScreen guidance | HIGH | LOW | P1 |
| Single-file installer (Inno Setup / NSIS) | HIGH | MEDIUM | P1 |
| All installer actions atomic (DLL + registry + manifest + shortcuts) | HIGH | MEDIUM | P1 |
| Full uninstaller with registry + temp cleanup | HIGH | MEDIUM | P1 |
| Accelerated post-install polling + success toast | HIGH | MEDIUM | P1 |
| "Still not connected?" recovery + log link | HIGH | LOW | P1 |
| Idempotent installer (upgrade in place) | HIGH | LOW | P1 |
| Version.txt + READY version field | MEDIUM | LOW | P1 |
| `go test -race` in CI | HIGH | LOW | P1 |
| buildFullMIME direct tests + Gmail HTTP mocking | HIGH | LOW | P1 |
| Playwright E2E happy path | HIGH | HIGH | P1 |
| C++ DLL conversion smoke test | MEDIUM | MEDIUM | P1 |
| SignPath.io signed release | HIGH | MEDIUM | P1 (best effort) |
| Diagnostic copy button | MEDIUM | MEDIUM | P2 |
| PING/PONG handshake test | MEDIUM | LOW | P2 |
| Installer CI smoke test | HIGH | HIGH | P2 |
| Version mismatch detection + update prompt | MEDIUM | LOW | P2 |
| v1.0.0 install cleanup | LOW | MEDIUM | P2 |
| Mutation testing on MIME/validator | LOW | MEDIUM | P3 |
| HKCU install mode (if MAPI allows) | MEDIUM | HIGH | P3 |
| Corporate-lock detection | LOW | HIGH | P3 |
| Pre-install environment probe | LOW | HIGH | P3 |

**Priority key:**
- P1: Required for v2.0.0 release
- P2: Add post-release if real usage justifies
- P3: Future milestone or never

---

## Competitor Feature Analysis

| Feature | 1Password | Bitwarden | KeePassXC-Browser | MetaMask | go-mapi v2.0.0 plan |
|---------|-----------|-----------|-------------------|----------|---------------------|
| Host-missing error clarity | Generic "desktop app required" | "Awaiting confirmation from desktop" (forever) | "Key exchange was not successful" (opaque) | N/A (no native host) | Explicit "not installed" vs "disconnected" state |
| Install trigger from extension | Docs link to downloads page | Docs link to downloads page | Docs link to GitHub wiki | Docs link to metamask.io | Direct download URL, one click |
| Auto-reconnect after install | Requires browser restart per community reports | Manual reconnect in many cases | Manual "reconnect" button | N/A | Accelerated polling (2s for 2min) + auto-reconnect |
| Success confirmation | Extension UI flips silently | Extension UI flips silently | Extension UI flips silently | N/A | Explicit toast + state change |
| Error recovery | Full troubleshooting wiki (overwhelming) | Forum threads | Wiki with 40+ items | Chrome store redirect | 3 bullets + log file link |
| Tray icon / background service | YES (has standalone function) | YES (has standalone function) | YES (has standalone function) | N/A | NO (no standalone function) |
| Code-signed installer | YES (paid EV cert) | YES (paid EV cert) | YES (OSS signing) | N/A (web install) | Best-effort via SignPath |
| Uninstall cleanliness | Good | OK (NativeMessagingHosts sometimes left behind) | OK | N/A | Full cleanup including `%TEMP%` |
| Telemetry | Opt-out | Opt-in | None | Extensive | None (privacy baseline) |

**go-mapi's competitive angle:** The combination of "auto-reconnect after install + success toast + no tray icon + full uninstall + zero telemetry" isn't shipped by any of the above. Bitwarden and KeePassXC have the FOSS ethos but bad install UX. 1Password has good install UX but pays for it with telemetry, tray icons, and a proprietary stack. go-mapi v2.0.0 can occupy the "polished install UX + FOSS ethos" gap.

---

## Sources

**Comparable products and community post-mortems:**
- [1Password browser troubleshooting](https://support.1password.com/1password-browser-troubleshooting/) — MEDIUM confidence, official docs
- [Bitwarden community: native messaging discussion](https://community.bitwarden.com/t/why-doesnt-the-browser-extension-use-native-messaging/42757) — MEDIUM confidence, community forum
- [Bitwarden issue: NativeMessagingHosts file missing](https://github.com/bitwarden/clients/issues/18996) — HIGH confidence, official bug tracker
- [KeePassXC-Browser troubleshooting guide](https://github.com/keepassxreboot/keepassxc-browser/wiki/Troubleshooting-guide) — HIGH confidence, official wiki
- [KeePassXC issue #559: unhelpful error when host not set up](https://github.com/keepassxreboot/keepassxc-browser/issues/559) — HIGH confidence, direct evidence of the UX gap go-mapi can fill
- [Claude-in-Chrome reconnect failures (issue #14894, #22885, #15463)](https://github.com/anthropics/claude-code/issues/14894) — HIGH confidence, reproducible bug patterns
- [MetaMask onboarding detection issue on Brave](https://github.com/MetaMask/metamask-onboarding/issues/53) — MEDIUM confidence
- [JabRef native host not found issue](https://github.com/JabRef/JabRef-Browser-Extension/issues/461) — MEDIUM confidence

**Platform and installer tooling:**
- [Chrome native messaging official docs](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) — HIGH confidence, authoritative
- [Web-to-app communication: Native Messaging API (textslashplain)](https://textslashplain.com/2020/09/04/web-to-app-communication-the-native-messaging-api/) — MEDIUM confidence, HKCU vs HKLM tradeoffs
- [Microsoft Edge native messaging docs](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/native-messaging) — HIGH confidence
- [SignPath Foundation (free OSS code signing)](https://signpath.org/) and [SignPath open source solution](https://signpath.io/solutions/open-source-community) — HIGH confidence, official
- [DB Browser for SQLite: journey with SignPath](https://sqlitebrowser.org/blog/signing-windows-executables-our-journey-with-signpath/) — HIGH confidence, FOSS-project case study
- [Inno Setup 2026 review](https://blog.thefix.it.com/is-inno-setup-good-the-definitive-2026-developer-review/) — MEDIUM confidence
- [NSIS vs WiX 2026 guide](https://copyprogramming.com/howto/nsis-vs-wix-vs-anyother-installation-package) — MEDIUM confidence

**Windows install UX / SmartScreen:**
- [Advanced Installer: preventing SmartScreen warnings](https://www.advancedinstaller.com/prevent-smartscreen-from-appearing.html) — MEDIUM confidence
- [Unsigned EXE SmartScreen 2026 behavior](https://copyprogramming.com/howto/how-does-this-unsigned-exe-launch-without-the-windows-10-smartscreen-warning) — LOW-MEDIUM confidence, single source on 25H2 Kernel Isolation specifics — the 15,000-downloads reputation threshold is widely cited but specific to 24H2/25H2 policy, flag for validation
- [GitExtensions SmartScreen warning discussion](https://github.com/gitextensions/gitextensions/issues/7738) — MEDIUM confidence, FOSS-project perspective
- [The Register: Windows 10 SmartScreen seven-step install](https://www.theregister.com/2020/06/05/windows_10_microsoft_defender_smartscreen/) — MEDIUM confidence, dated but illustrative

**Testing:**
- [DEV: Chrome extension E2E with Playwright + CDP](https://dev.to/corrupt952/how-i-built-e2e-tests-for-chrome-extensions-using-playwright-and-cdp-11fl) — MEDIUM confidence
- [BrowserStack: Playwright Chrome extension guide](https://www.browserstack.com/guide/playwright-chrome-extension) — MEDIUM confidence
- [Trunk.io: flaky tests in Playwright](https://trunk.io/learn/how-to-avoid-and-detect-flaky-tests-in-playwright) — MEDIUM confidence
- [Semaphore: avoiding Playwright flakes](https://semaphore.io/blog/flaky-tests-playwright) — MEDIUM confidence

---

*Feature research for: Windows native-host installer UX paired with a browser extension (go-mapi v2.0.0)*
*Researched: 2026-04-10*
