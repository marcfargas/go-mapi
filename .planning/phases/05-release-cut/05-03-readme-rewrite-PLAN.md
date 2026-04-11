---
phase: 05-release-cut
plan: 03
type: execute
wave: 1
depends_on: []
files_modified:
  - README.md
autonomous: true
requirements: [REL-03]
must_haves:
  truths:
    - "A non-technical Windows user reading README.md sees a three-step install flow: download the installer from GitHub Releases, click through SmartScreen, single UAC prompt (D-06)"
    - "The dev-oriented install-via-irm-install.ps1 path is preserved in a `## Development` section so existing contributor muscle memory still works"
    - "The README `## Installation` section links to the same `releases/latest/download/go-mapi-setup.exe` URL that `InstallPrompt.tsx` uses (REL-03 + EXT-07 consistency)"
    - "The README has an Uninstall pointer (Settings → Apps → go-mapi → Uninstall) consistent with `.github/release-template.md`"
  artifacts:
    - path: "README.md"
      provides: "End-user-first install instructions with SmartScreen walkthrough"
      contains: "releases/latest/download/go-mapi-setup.exe"
      min_lines: 100
  key_links:
    - from: "README.md Installation section"
      to: "https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe"
      via: "direct link"
      pattern: "releases/latest/download/go-mapi-setup.exe"
    - from: "README.md SmartScreen section"
      to: ".github/release-template.md"
      via: "same 3-step walkthrough (More info → Run anyway → UAC)"
      pattern: "More info"
---

<objective>
Rewrite `README.md`'s install-related sections so a non-technical Windows user can install go-mapi v2.0.0 by downloading the installer from GitHub Releases and clicking through SmartScreen + UAC, per D-06 and REL-03. The current `## Quick Start` section is dev-oriented (tells users to run `irm | iex` against `scripts/install.ps1`), which contradicts the v2.0.0 core value statement ("non-technical Windows user ... without touching a terminal"). This plan replaces the user-facing install flow with the real v2.0.0 distribution path and moves dev-oriented instructions into a clearly-labeled `## Development` section so contributors can still find them.

Purpose: The README is the single most visible piece of user-facing documentation in the repo. If it still tells users to open admin PowerShell and run `irm ... | iex`, the v2.0.0 shipping gate is half-closed. REL-03 is the other half of REL-05 — a shipped installer with a README that still points at the legacy flow is worse than no README change.
Output: Rewritten `README.md` with `## Installation` (end-user), `## Usage`, `## If Windows SmartScreen blocks the installer`, `## Uninstall`, and `## Development` sections.
</objective>

<execution_context>
@C:/dev/go-mapi/.claude/get-shit-done/workflows/execute-plan.md
@C:/dev/go-mapi/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/phases/05-release-cut/05-CONTEXT.md
@.github/release-template.md
@src/extension/src/popup/InstallPrompt.tsx
@README.md

<interfaces>
<!-- Canonical SmartScreen walkthrough (from .github/release-template.md):
     1. Click the small **More info** link in the SmartScreen dialog.
     2. A **Run anyway** button appears below the publisher line. Click it.
     3. Proceed with the normal UAC prompt and wizard.
     → README MUST reuse this exact 3-step phrasing so the message is consistent
       between the download page (release notes) and the project README.
-->

<!-- Stable download URL (locked in Phase 3 / EXT-07):
     https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe
     Used by:
     - src/extension/src/popup/InstallPrompt.tsx:5  (INSTALLER_DOWNLOAD_URL)
     - .github/release-template.md:7
     README MUST use this exact URL for consistency.
-->

<!-- Five supported Chromium-family browsers (from src/installer/go-mapi.iss [Registry] section):
     Chrome, Edge, Chromium, Brave, Vivaldi
     (EXT-05 / INST-03 copy matches this list. README must be consistent.)
-->

<!-- Current README.md sections (from Read of README.md 1-186):
     1. Title + tagline (lines 1-3)
     2. Overview (lines 5-13)
     3. Status table (lines 15-31) — references "v1.0.0 Stable", needs update to v2.0.0
     4. Architecture ASCII diagram (lines 33-69) — KEEP
     5. Quick Start (lines 71-149) — REPLACE: currently tells users to run irm|iex
     6. Enterprise Deployment (lines 151-158) — KEEP but update the install.ps1 references to note the new flow
     7. Why "go-mapi"? (lines 160-162) — KEEP
     8. Contributing (lines 164-169) — KEEP
     9. License (lines 171-178) — KEEP
     10. References (lines 180-186) — KEEP
-->
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Rewrite README.md install-related sections for v2.0.0 end-user flow</name>
  <files>README.md</files>
  <read_first>
    - README.md (ENTIRE file — preserve the Architecture diagram, Why section, Contributing, License, and References verbatim; rewrite Status table + Quick Start only)
    - .github/release-template.md (lines 12-44 for the Installation / SmartScreen / What-the-installer-does / Uninstall / Privacy sections — the README SmartScreen walkthrough MUST use the same 3-step phrasing)
    - src/extension/src/popup/InstallPrompt.tsx (confirm `INSTALLER_DOWNLOAD_URL` is exactly `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`)
  </read_first>
  <action>
    Use the Edit tool to rewrite specific sections of `README.md`. Do NOT use Write (which would lose the untouched sections). Make three edits:

    **Edit 1 — Status table (lines ~15-31)**. Replace the table heading text `**v1.0.0 Stable** — Production-ready for personal and enterprise use.` and the subsequent `What's Next:` line with:

    ```markdown
    **v2.0.0** — First shipped milestone with a single-click Windows installer and a full Chromium-family browser extension. See [Installation](#installation) for the end-user flow.

    | Component | Status |
    |-----------|--------|
    | MAPI interception (ANSI + Unicode) | ✅ Stable |
    | Native messaging bridge | ✅ Stable |
    | Browser extension (popup + notifications) | ✅ Stable |
    | Gmail draft creation (with attachments) | ✅ Stable |
    | UTF-8 / codepage encoding | ✅ Stable |
    | Single-click Windows installer (Inno Setup 6) | ✅ v2.0.0 |
    | Chrome / Edge / Chromium / Brave / Vivaldi | ✅ v2.0.0 |
    | Windows Sandbox local repro | ✅ v2.0.0 (`tests/sandbox/`) |
    ```

    **Edit 2 — Replace `## Quick Start` with `## Installation` + three end-user subsections**. Find the `## Quick Start` heading (around line 71) and replace EVERYTHING from `## Quick Start` through and including `The uninstaller removes all registry entries and restores your previous default mail client.` (around line 149) with:

    ```markdown
    ## Installation

    **For end users.** No terminal, no toolchain, no admin PowerShell required.

    ### Prerequisites

    - Windows 10 or 11
    - Chrome, Edge, Chromium, Brave, or Vivaldi
    - A Gmail or Google Workspace account

    ### Install the Windows host

    1. Download `go-mapi-setup.exe` from the latest GitHub Release:

       **[Direct download: go-mapi-setup.exe](https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe)**

       This link always points at the latest stable release.

    2. Run the installer. You will see **one UAC prompt** — click **Yes**. The
       installer copies the binaries to `C:\Program Files\go-mapi\`, registers
       go-mapi as the default Windows Mail client, and writes native-messaging
       registry entries for Chrome, Edge, Chromium, Brave, and Vivaldi in one
       shot.

    3. Install the browser extension. For v2.0.0 the Chrome Web Store listing
       is pending review — in the meantime, load the unpacked extension from
       the release ZIP asset attached to the same GitHub Release.

    ### If Windows SmartScreen blocks the installer

    You may see a blue **"Windows protected your PC"** dialog when you first
    run `go-mapi-setup.exe`. This happens because the v2.0.0 installer ships
    unsigned — the project's code-signing certificate (via the SignPath
    Foundation OSS program) is in review at the time of this release. The
    installer is safe: the source is public on GitHub, and every release is
    built from a reproducible GitHub Actions workflow (see
    `.github/workflows/installer-release.yml`).

    To continue the install:

    1. Click the small **More info** link in the SmartScreen dialog.
    2. A **Run anyway** button appears below the publisher line. Click it.
    3. Proceed with the normal UAC prompt and installer wizard.

    This is a one-time click-through per downloaded file — subsequent runs of
    the same `go-mapi-setup.exe` don't show the dialog again. A signed
    installer will ship as v2.0.1 once SignPath approval lands, at which
    point this section becomes unnecessary.

    ## Usage

    1. Right-click any file in Windows Explorer → **Send to** → **Mail recipient**
       (or trigger any other Windows "Send by Email" action).
    2. The email appears in the go-mapi browser extension popup as a Gmail
       draft preview.
    3. Click **Save as Draft** to push it to your Gmail drafts folder (or
       **Delete** to discard it).

    That's it. No per-user setup, no extra prompts, and the extension
    auto-detects the host once it's installed — if you install the extension
    first and then the host, the extension's "Install go-mapi" banner
    disappears within six seconds and a one-time success toast confirms the
    handshake.

    ## Uninstall

    Windows **Settings → Apps → Installed apps → go-mapi → Uninstall**, or
    run the uninstaller directly at `C:\Program Files\go-mapi\unins000.exe`.

    Uninstall removes every file and registry entry the installer wrote
    (DLL, native host binary, all five browser registry trees, the MAPI
    handler registration, `%TEMP%\go-mapi\` leftovers) and restores the
    previous default Mail client from the backup file saved during install
    (`C:\ProgramData\go-mapi\uninst\previous-mail-client.json`).

    ## Privacy

    go-mapi is privacy-first by design:

    - No telemetry of any kind. No update-check beacons, no crash reporting.
    - No long-term storage of message content. Transient JSON files under
      `%TEMP%\go-mapi\` are deleted immediately after you click **Save as
      Draft** or **Delete**.
    - No network calls except to the Gmail API, on your behalf, to create
      the draft.
    - No background service, no tray icon, no auto-start.
    ```

    **Edit 3 — Replace `## Enterprise Deployment` section's `install.ps1 -Unattended` reference** and append a new `## Development` section just BEFORE the existing `## Why "go-mapi"?` section. Find the `## Enterprise Deployment` block and replace it with:

    ```markdown
    ## Enterprise Deployment

    For managed Windows environments:

    - **Silent install**: `go-mapi-setup.exe /VERYSILENT /SUPPRESSMSGBOXES` — the Inno Setup installer supports the standard `/VERYSILENT`, `/SILENT`, and `/LOG=<path>` switches. See the [Inno Setup Setup command line](https://jrsoftware.org/ishelp/index.php?topic=setupcmdline) documentation for the full list.
    - **Extension deployment**: force-install via Chrome/Edge enterprise policy ([`ExtensionInstallForcelist`](https://chromeenterprise.google/policies/#ExtensionInstallForcelist)).
    - **Registry**: all state is under `HKLM\SOFTWARE\Clients\Mail\go-mapi` and the five `HKLM\SOFTWARE\*\NativeMessagingHosts\com.gomapi.host` trees. Export these keys from a reference machine for GPO-based deployment if needed.
    - **OAuth**: the extension uses the Chrome Identity API against a GCP OAuth client baked into `src/extension/public/manifest.json`. For enterprise deployments, fork the extension and replace the OAuth client ID with your own GCP project's credentials.

    ## Development

    **For contributors building from source.** If you're just installing
    go-mapi to use it, you want the [Installation](#installation) section
    above instead.

    ### Prerequisites

    - Windows 10/11 + Admin PowerShell
    - Node 18+ and npm 9+
    - Go 1.21+
    - MinGW with gcc/g++ toolchain (for the C++ interceptor DLL)
    - CMake 3.16+
    - Chrome or Edge for extension testing

    ### Build everything

    ```powershell
    npm ci                         # install extension dev dependencies
    npm run build:interceptor      # MinGW + CMake → src/interceptor/build/bin/go-mapi.dll
    npm run build:native-host      # Go → src/native-host/build/go-mapi-host.exe
    npm run build:extension        # Vite → src/extension/dist/
    ```

    ### Install from local build (dev loop)

    ```powershell
    # From an admin PowerShell on the build host:
    .\scripts\install.ps1 -Local
    ```

    The legacy `scripts/install.ps1` path is still supported for contributors
    who want to test an unreleased build without compiling the Inno Setup
    installer every iteration. It uses the same `.tmpl` native-messaging
    manifests as the production installer (FOUND-06), so the resulting
    registry state is identical.

    ### Build the Inno Setup installer locally

    ```powershell
    & "C:\Program Files (x86)\Inno Setup 6\iscc.exe" `
        /DGOMAPIVersion=2.0.0-local `
        src\installer\go-mapi.iss
    # → src\installer\dist\go-mapi-setup.exe
    ```

    ### Run the test suites

    ```powershell
    cd src\native-host && go test ./... ; cd ..\..
    cd src\interceptor && cmake .. -G "MinGW Makefiles" -DBUILD_TESTS=ON && cmake --build . && ctest --output-on-failure ; cd ..\..
    cd src\extension && npm run test:run ; cd ..\..
    npx playwright test --config tests\e2e\playwright.config.ts
    ```

    ### Local Windows Sandbox repro (REL-02)

    See [`tests/sandbox/README.md`](tests/sandbox/README.md) for the local
    install → verify → uninstall repro path. Requires Windows 11 24H2+ and
    the `wsb` CLI.

    ### CI workflows

    - `.github/workflows/build.yml` — per-PR Go + C++ + TypeScript build and test
    - `.github/workflows/installer-smoke.yml` — per-PR Pester 5 installer smoke test on `windows-latest`
    - `.github/workflows/e2e.yml` — Playwright happy-path + install UX on `windows-latest`
    - `.github/workflows/go-race-nightly.yml` — nightly `go test -race` on `windows-latest` amd64
    - `.github/workflows/installer-release.yml` — tag-triggered SignPath-gated installer release

    ### Troubleshooting a local install

    - **DLL not found** — verify `C:\Program Files\go-mapi\go-mapi.dll` exists and `HKLM\SOFTWARE\Clients\Mail\go-mapi\DLLPath` points at it.
    - **Extension shows "Install the go-mapi host" after installing** — wait up to 6 seconds for the reconnect alarm. If the prompt doesn't clear, check the service worker console in `chrome://extensions` and the host log at `%TEMP%\go-mapi\native-host.log`.
    - **"Send to → Mail recipient" doesn't appear** — restart Windows Explorer (`taskkill /im explorer.exe /f && start explorer.exe`) so the shell picks up the new MAPI handler registration.
    ```

    **Do NOT touch:** the `## Overview`, `## Architecture`, `## Why "go-mapi"?`, `## Contributing`, `## License`, and `## References` sections. They remain verbatim.

    Commit with: `docs(05-03): rewrite README.md install flow for v2.0.0 end-user distribution (REL-03)`
  </action>
  <verify>
    <automated>grep -q "^## Installation$" README.md &amp;&amp; grep -q "releases/latest/download/go-mapi-setup.exe" README.md &amp;&amp; grep -q "More info" README.md &amp;&amp; grep -q "Run anyway" README.md &amp;&amp; grep -q "^## Development$" README.md &amp;&amp; grep -q "^## Uninstall$" README.md &amp;&amp; grep -q "^## Usage$" README.md &amp;&amp; ! grep -q "irm https" README.md &amp;&amp; grep -q "unins000.exe" README.md &amp;&amp; grep -q "Chrome, Edge, Chromium, Brave, or Vivaldi" README.md</automated>
  </verify>
  <acceptance_criteria>
    - `grep -q "^## Installation$" README.md` matches (new heading exists)
    - `grep -q "^## Usage$" README.md` matches
    - `grep -q "^## Uninstall$" README.md` matches
    - `grep -q "^## Development$" README.md` matches
    - `grep -q "https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe" README.md` matches (links to the exact URL `InstallPrompt.tsx` uses)
    - `grep -q "More info" README.md` matches (SmartScreen step 1)
    - `grep -q "Run anyway" README.md` matches (SmartScreen step 2)
    - `grep -q "unins000.exe" README.md` matches (Uninstall pointer)
    - `grep -q "Chrome, Edge, Chromium, Brave, or Vivaldi" README.md` matches (five browsers consistent with INST-03)
    - `grep -q "tests/sandbox/README.md" README.md` matches (Development section points at REL-02 local repro)
    - `grep -q "irm https" README.md` returns NO match (legacy one-liner install removed from end-user flow)
    - `grep -q "## Quick Start" README.md` returns NO match (section replaced)
    - `grep -q "## Architecture" README.md` matches (preserved section still present)
    - `grep -q "## License" README.md` matches (preserved section still present)
    - `grep -q "LGPL-3.0" README.md` matches (license text preserved)
    - README.md is at least 100 lines (not accidentally truncated)
  </acceptance_criteria>
  <done>
    A non-technical Windows user can read the README top-down and install v2.0.0 without seeing a single terminal command in the happy path. Contributors can still find build/test instructions in the `## Development` section.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| README.md → user's browser → GitHub Releases URL | User clicks the link in README and downloads the installer from github.com (TLS-terminated by GitHub) |
| README.md → user's local SmartScreen decision | README documents the "Run anyway" click-through, training users to bypass a Windows security warning |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-05-03-01 | Spoofing | README download link pointing at a typo/hijacked URL | mitigate | The acceptance criterion grep-matches the EXACT string `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`, the same string used by `InstallPrompt.tsx:5` and `.github/release-template.md:7`. A replay of this plan will fail if any character drifts. Cross-reference with the in-context extraction of `INSTALLER_DOWNLOAD_URL` from InstallPrompt.tsx. |
| T-05-03-02 | Tampering | SmartScreen guidance reading as "always click through Windows security" | mitigate | README's SmartScreen section explicitly scopes the click-through to "this project ships unsigned pending SignPath approval" and notes "signed installer will ship as v2.0.1 once SignPath approval lands, at which point this section becomes unnecessary." Does not generalize the click-through to other installers. Reuses the exact 3-step phrasing from `.github/release-template.md` so the message is consistent with the release notes the user also sees. |
| T-05-03-03 | Information Disclosure | README exposing developer paths or internal infrastructure | accept | All paths referenced (`C:\Program Files\go-mapi\`, `C:\ProgramData\go-mapi\`, `%TEMP%\go-mapi\`) are public from `.github/release-template.md` already. No blegal.dev references per `~/.claude/rules/confidentiality.md`. |
| T-05-03-04 | Repudiation | User following README install instructions and then blaming go-mapi for SmartScreen warning | accept | README explains WHY SmartScreen warns (unsigned pending SignPath) and notes the signed v2.0.1 re-cut path. Provides context, not just instructions. |
| T-05-03-05 | Elevation of Privilege | README telling users to disable Windows Defender or add exclusions | accept | README does NOT ask users to disable Defender, disable SmartScreen globally, or add exclusions. The SmartScreen walkthrough is per-file and standard Microsoft-documented behavior. |
</threat_model>

<verification>
- `grep -c "^## " README.md` shows all expected headings: Overview, Status, Architecture, Installation, Usage, If Windows SmartScreen blocks the installer, Uninstall, Privacy, Enterprise Deployment, Development, Why "go-mapi"?, Contributing, License, References
- `grep -q "releases/latest/download/go-mapi-setup.exe" README.md` matches (twice — once in the main link, possibly once elsewhere)
- `grep -q "irm https" README.md` returns NO match — the legacy `irm | iex` one-liner is NOT in the end-user install path anymore
- `grep -q "## Development" README.md` matches AND is positioned BEFORE `## Why "go-mapi"?` (dev instructions preserved, just moved)
- URL consistency: `grep "go-mapi-setup.exe" README.md` and `grep "go-mapi-setup.exe" src/extension/src/popup/InstallPrompt.tsx` both show the same full URL
</verification>

<success_criteria>
REL-03 closed: `README.md` install-related sections are rewritten for the v2.0.0 GitHub Releases distribution flow. The download link points at the exact URL `InstallPrompt.tsx` links to. SmartScreen guidance matches `.github/release-template.md`. Dev-oriented install instructions are preserved in a `## Development` section so contributors can still find them.
</success_criteria>

<output>
After completion, create `.planning/phases/05-release-cut/05-03-SUMMARY.md` per the standard summary template.
</output>
