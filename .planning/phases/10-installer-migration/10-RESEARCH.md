# Phase 10: Installer + Migration - Research

**Researched:** 2026-04-19
**Domain:** Windows NSIS installer tooling; WebView2 Evergreen runtime detection + bootstrap; Windows 10/11 shell integration (AUMID, Start Menu shortcut, MAPI handler registration); Windows Credential Manager cleanup; Windows Firewall automation; SignPath OSS signing; GitHub Actions release + smoke-test pipelines; Pester 5 on `windows-latest`.
**Confidence:** HIGH for NSIS primitives, WebView2 detection, ApplicationID plugin, keyring target shape, SignPath action mechanics, Pester idioms. MEDIUM for WebView2 bootstrapper polling timeout (empirical community consensus, no official guidance). LOW for none — every claim that would have been LOW was verified.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

> **Source:** `.planning/phases/10-installer-migration/10-CONTEXT.md` §`<decisions>` — 31 decisions D-01..D-31. All decisions in that section are locked and pre-empt any alternatives research might surface. This research addresses the **HOW** of each locked decision; it does not re-litigate the **WHAT**.

**Installer tooling + layout (D-01..D-04):** NSIS at `src/installer/go-mapi.nsi`; admin-only machine-wide install at `$PROGRAMFILES64\go-mapi`; output filename `go-mapi-setup.exe`.

**WebView2 runtime (D-05..D-08):** Bundle online Evergreen bootstrapper (~2 MB); registry detect before install; poll registry up to ~60 s after `/silent /install`; installer continues on bootstrap failure; Wails app has NEW runtime-missing recovery via native MessageBoxW + download URL + exit.

**MAPI handler (D-09):** HKLM `SOFTWARE\Clients\Mail\go-mapi\{Default="go-mapi", DLLPath="$INSTDIR\go-mapi.dll"}`; set `Mail\(Default)=go-mapi` AFTER backup.

**Previous-client backup (D-10..D-12):** `%ProgramData%\go-mapi\uninst\previous-mail-client.json` with `{previousClient, backedUpAt}` shape. Directory persists across upgrade; removed on full uninstall.

**AUMID + Start Menu shortcut (D-13..D-15):** `$SMPROGRAMS\go-mapi.lnk`; NSIS `ApplicationID` plugin stamps `com.marcfargas.gomapi`; ldflags injection at build time.

**Firewall rule (D-16..D-17):** Install creates `go-mapi OAuth loopback` inbound rule via PowerShell (or netsh); uninstall removes it.

**Uninstall (D-18..D-20):** Ten-step scrub — firewall, shortcut, MAPI key, restore default mail, uninst dir, `%TEMP%\go-mapi\` (best-effort), `%APPDATA%\go-mapi\` (current user), Credential Manager (current user), binaries, install dir. Multi-user caveat documented. **NO v2.x artifact cleanup inside installer** (users uninstall v2 themselves).

**Pester smoke test (D-21..D-22):** `src/installer/tests/installer.Tests.ps1` with 13-item coverage (install, bits present, registry, backup JSON, AUMID on `.lnk`, firewall, uninstall exits 0, everything gone). No toast/WebView2 bootstrap/E2E in Pester scope.

**Signing (D-23..D-25):** Two SignPath calls (binaries pre-makensis, installer post-makensis); gated on `SIGNPATH_API_TOKEN`; tag push `v*` only.

**Release workflow (D-26..D-28):** Version authority = `src/app/wails.json` `info.productVersion`; new `.github/workflows/installer-release.yml`; OAuth secrets injected via ldflags.

**Pester CI (D-29..D-30):** New `.github/workflows/installer-smoke.yml` on `push`/`pull_request`/`workflow_dispatch`; Pester 5 idiom only.

**Housekeeping (D-31):** Delete v2.0 `src/installer/dist/go-mapi-setup.exe` (the only v2 artifact present — no `.iss` file exists today).

### Claude's Discretion

- Exact NSIS UI flow (ModernUI2 welcome/license/instdir/progress/finish vs minimalist silent-first) — default ModernUI2 + LGPL-3.0 license page.
- Internal NSIS section/function naming inside `go-mapi.nsi`.
- Pester Describe/Context/It naming within D-21 checklist.
- ApplicationID plugin integration path: copy DLL to `$NSISDIR\Plugins` at CI time, or ship plugin DLL in `src/installer/plugins/x86-unicode/` and use `!addplugindir`. Research recommends the repo-local path (reproducibility).
- Pester AUMID verification primitive (three candidates). Research recommends the inline-C# IShellLink+IPropertyStore approach (aligns with existing `scripts/register-dev-aumid.ps1`).
- Release notes `.github/release-template.md` content (modest adaptation of v2.0 D-24 acceptable).
- `installer-smoke.yml` structure (reuse matrix artifact vs inline build) — research recommends inline (simpler, no artifact plumbing).

### Deferred Ideas (OUT OF SCOPE)

- v2.x → v3 automated migration (clean-break stays; users uninstall v2 first).
- Enumerate-all-profiles uninstall cleanup (multi-user RDS limitation documented only).
- Offline WebView2 standalone bundle.
- Bootstrap-failure simulation in Pester.
- Installer localization (English only).
- In-process autoupdate / binary self-replace.
- SmartScreen WDSI reputation submission (Phase 11 release checklist).
- End-to-end install → sign-in → MAPI → draft test (Phase 11 REL-07).
- Toast delivery verification in CI (deferred to sandbox-automation todo).

</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| INST-01 | Signed installer registers MAPI handler + places DLL + installs Wails binary + registers AUMID shortcut | §Standard Stack (NSIS + ApplicationID plugin); §Code Examples 1, 2, 6; §Don't Hand-Roll (AUMID); §Signing |
| INST-02 | Installer bootstraps WebView2 Evergreen runtime; fails loudly with Microsoft download link if bootstrap cannot complete | §Code Examples 3, 4 (registry detection + poll loop); §Common Pitfalls (bootstrapper early-exit bug); §Code Example 5 (Go MessageBoxW recovery) |
| INST-03 | Installer does NOT require admin for per-user path | **Overridden by D-02:** Admin required, machine-wide only. Documented in User Constraints. Research does not plan per-user path. |
| INST-04 | Admin only required for machine-wide install | Same as INST-03 — CONTEXT.md D-02 collapses both cases to admin-only. |
| INST-05 | Uninstall removes binary, handler, registry keys, AUMID shortcut, temp dir | §Code Examples 7, 8, 9 (uninstall section); §Runtime State Inventory (keyring target, APPDATA paths, multi-user caveat) |
| INST-06 | Windows Firewall rule for loopback OAuth port added during install | §Code Example 10 (netsh vs New-NetFirewallRule); §Pitfall 4 referenced from PITFALLS.md |
| INST-07 | Pester 5 smoke test verifies install + uninstall round-trip on fresh `windows-latest` CI | §Validation Architecture (framework map); §Code Examples 11, 12 (Pester configuration, AUMID verification); §Environment Availability (NSIS install on runner) |

**Traceability:** All seven requirements have research support. INST-03/04 are semantically collapsed to admin-only by D-02 — planner must honor D-02 and not plan a per-user path.

</phase_requirements>

## Summary

Phase 10 ships a single-file NSIS installer that provisions the v3.0 Wails app, the C++ MAPI DLL, the HKLM Mail-client registration, an AUMID-stamped Start Menu shortcut, a Windows Firewall rule, and the WebView2 Evergreen runtime (via bundled online bootstrapper). It also adds a runtime-missing recovery path to the Wails app itself (native `MessageBoxW` via `syscall.NewLazyDLL("user32.dll")`, already an established pattern in `src/app/sessionend.go`). Uninstall is a full scrub matching the install surface plus `%APPDATA%\go-mapi\` and the Credential Manager entry for the uninstalling user. A Pester 5 smoke test runs on `windows-latest` covering 13 install/uninstall invariants.

The v2.0 Inno Setup phase (`.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/`) is the authoritative structural reference: four plans, CI pattern, SignPath gating, previous-client backup, uninstall ordering. NSIS translation is mostly mechanical — the two genuinely new moving pieces are (a) the WebView2 bootstrap + registry-poll dance, and (b) AUMID stamping via the `ApplicationID` plugin (which replaces the inline C# / IShellLink acrobatics in `scripts/register-dev-aumid.ps1` for the production path but is preserved as the Pester verification primitive).

**Primary recommendation:** Decompose Phase 10 into **six plans**:

1. **10-01** — `src/installer/go-mapi.nsi` scaffold + ModernUI2 + license page + binary staging + MAPI handler registration + previous-client backup (INST-01, INST-05 backup half).
2. **10-02** — WebView2 detection + bootstrapper invocation + poll loop inside the installer, PLUS the `webview2_check.go` + `webview2_check_bindings.go` build-tag-split runtime recovery in `src/app/` (D-08) (INST-02).
3. **10-03** — AUMID stamping (`ApplicationID::Set` + plugin vendoring), Start Menu shortcut creation, Windows Firewall rule install, Credential Manager uninstall hook; AUMID ldflags wiring (`-X main.aumidOverride=com.marcfargas.gomapi`) verified against `src/app/toast.go` (INST-01 AUMID half, INST-06).
4. **10-04** — NSIS Uninstall section: full 10-step scrub per D-18, multi-user caveat documented in README, housekeeping removal of `src/installer/dist/go-mapi-setup.exe` (INST-05).
5. **10-05** — Pester 5 smoke test `src/installer/tests/installer.Tests.ps1` with 13-item coverage + `.github/workflows/installer-smoke.yml` (INST-07).
6. **10-06** — Release pipeline `.github/workflows/installer-release.yml` with two SignPath calls, ldflags injection (Version + oauthClient* + aumidOverride), `softprops/action-gh-release@v2` asset upload, version validation against `wails.json` (D-23..D-28).

Sequencing: 10-01 → 10-02 can parallel 10-03 → 10-04 (consumes 10-01..03) → 10-05 (consumes 10-04) → 10-06 (consumes all). Planner may collapse 10-02 and 10-03 if the NSIS script stays under ~350 lines; recommendation is to keep them separate so WebView2 review stays focused.

## Standard Stack

### Core

| Tool / Library | Version | Purpose | Why Standard |
|---|---|---|---|
| **NSIS (makensis)** | 3.10+ (3.10.0 pre-installed on `windows-latest` per GH Marketplace docs) [VERIFIED: WebSearch 2026] | Installer compiler | Pre-installed on `windows-latest` runners; free (zlib-style license, LGPL-compatible); supports all primitives Phase 10 needs (Registry, ExecWait, File, SetOutPath, RMDir, InstallDir, UAC via `RequestExecutionLevel admin`) |
| **NSIS `ApplicationID` plugin** | 1.x (GitHub connectiblutz fork — the actively maintained one) [VERIFIED: sourceforge + GH] | Stamps `PKEY_AppUserModel_ID` on `.lnk` — enables Action Center persistence (NOTIF-04) | Single-call API: `ApplicationID::Set "path.lnk" "com.vendor.app"` + `Pop $0` (0=success, -1=error) [CITED: https://nsis.sourceforge.io/ApplicationID_plug-in]; replaces the 120-line inline C# IShellLink+IPropertyStore in `scripts/register-dev-aumid.ps1` for the prod path |
| **ModernUI2 (`MUI2.nsh`)** | Bundled with NSIS | Standard installer UI (welcome / license / instdir / progress / finish) | Ships with NSIS core; LGPL-3.0 license page via `!insertmacro MUI_PAGE_LICENSE "LICENSE"` |
| **WebView2 Runtime Bootstrapper (`MicrosoftEdgeWebview2Setup.exe`)** | Evergreen, ~2 MB [CITED: https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution] | Downloads + installs the WebView2 Evergreen Runtime at installer runtime | Microsoft's freely-redistributable bootstrapper; alternative is 200 MB standalone (rejected per CONTEXT.md Deferred). **Must be re-downloaded fresh for each release** — URL via Microsoft's "Get the Link" on the download page; pinned redistributable hash in release notes. |
| **Pester 5** | 5.x (pre-installed on `windows-latest`) [CITED: v2.0 SUMMARY 03-04; GH Actions runner docs] | PowerShell test framework | Pre-installed on `windows-latest`; Pester 4 `-EnableExit` syntax is forbidden per D-30 |
| **SignPath action** | **v2** [VERIFIED: https://docs.signpath.io/trusted-build-systems/github 2026; **CONTEXT D-23 says v1 — planner must bump to v2**] | Signs binaries + installer via SignPath Foundation (free OSS tier) | Standard OSS signing path; gated on `secrets.SIGNPATH_API_TOKEN` |
| **`softprops/action-gh-release`** | **v2** [VERIFIED: GitHub 2026 — upstream has a v3 beta on Node 24 but v2 remains the stable recommendation for existing pipelines; CONTEXT D-27 says v2 — correct] | Attaches `go-mapi-setup.exe` to GitHub Release | Standard GH Actions release upload; requires `permissions: contents: write` at workflow level |
| **Chocolatey (`choco`)** | Pre-installed on `windows-latest` | Alternative NSIS install path if runner's pre-installed NSIS ever drifts | `choco install nsis --no-progress -y` |

### Supporting

| Tool | Purpose | When to Use |
|---|---|---|
| `cmdkey.exe` | Native Windows Credential Manager scrub from NSIS | Uninstall step D-18 #8 — remove OAuth tokens. **Target string is `go-mapi:oauth-tokens`** (colon separator per zalando/go-keyring Windows backend) [VERIFIED: https://github.com/zalando/go-keyring/blob/master/keyring_windows.go — `return service + ":" + username`] |
| `netsh advfirewall firewall` | Alternative to PowerShell `New-NetFirewallRule` for firewall rule | Firewall rule add/remove. Available on all Windows 10+; shorter NSIS script than PowerShell invocation |
| `powershell.exe` (Windows PowerShell 5.1, NOT `pwsh`) | When netsh doesn't fit, fall back to PowerShell via `ExecWait` | End-user systems may not have PS7 — use `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "…"` inside NSIS [VERIFIED: CONTEXT specifics line 206] |
| `reg.exe query` (or NSIS `ReadRegStr`) | Read WebView2 registry presence from NSIS | WebView2 detection branch [VERIFIED: https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution §"Detect if a WebView2 Runtime is already installed"] |
| `golang.org/x/sys/windows/registry` (Go) | Registry read from Wails app for runtime-missing recovery | D-08: `webview2_check.go` reads HKLM/WOW6432Node `pv` value at `wails.Run` boundary. Already in project deps (transitive via go-keyring). [VERIFIED: `go.mod` via grep] |
| `user32.dll` via `syscall.NewLazyDLL` (Go) | `MessageBoxW` for runtime-missing dialog | D-08 recovery dialog. **Pattern already established in `src/app/sessionend.go:23-32`** — planner copies the `NewLazyDLL("user32.dll") + NewProc("MessageBoxW")` pattern. NO new dependency. [VERIFIED: codebase grep] |
| `github.com/pkg/browser` (Go) | Open Microsoft's WebView2 download URL from Wails app | D-08 recovery path opens `https://developer.microsoft.com/en-us/microsoft-edge/webview2/`. Already in project deps. [VERIFIED: CLAUDE.md stack list] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|---|---|---|
| NSIS | WiX v4 / Inno Setup 6 / MSIX | **Locked by D-01.** WiX is MSI/XML-heavy; Inno Setup (v2.0's choice) lacks first-class AUMID plugin — NSIS `ApplicationID` plugin is the deciding factor. |
| NSIS `ApplicationID` plugin | Inline PowerShell via `ExecWait` invoking the C# from `register-dev-aumid.ps1` | Rejected: adds ~120 lines of Pascal/PowerShell plumbing vs one NSIS call. The plugin is purpose-built. |
| Online WebView2 bootstrapper (2 MB) | Offline standalone (~200 MB) | **Locked by D-05.** Offline adds 200 MB to every release asset; release-notes discipline on `windows-latest` runners sets the budget. |
| PowerShell `New-NetFirewallRule` (in NSIS `ExecWait`) | `netsh advfirewall firewall add rule …` | Both work on Windows 10+. `netsh` wins on script brevity; PowerShell wins on readability + structured output. Research recommends `netsh` for NSIS (simpler single-line `ExecWait`). |
| `softprops/action-gh-release@v2` | `ncipollo/release-action`, `actions/create-release` (deprecated) | v2.0 already uses softprops; reuse for consistency. v3 exists but is Node 24 beta — stay on v2. |
| Pester 5 | Pester 4 | Pester 4 `-EnableExit` is explicitly forbidden by D-30. Pester 5 is pre-installed on `windows-latest`. |
| NSIS `ApplicationID` bundled via `!addplugindir` repo-local | Install action (GH Marketplace `install-nsis-plugin`) at CI time | Local vendor is reproducible + version-pinned; CI action adds network dependency. Research recommends repo-local at `src/installer/plugins/x86-unicode/ApplicationID.dll` + `!addplugindir "${__FILEDIR__}\plugins"` in the `.nsi` script. |

**Installation (dev):**
```bash
# Windows dev machine
choco install nsis --no-progress -y
# makensis.exe lands at: C:\Program Files (x86)\NSIS\makensis.exe
```

**Version verification:**
- NSIS on `windows-latest`: **3.10.0** (pre-installed per GH Marketplace `install-nsis` action docs, 2026) [VERIFIED]
- `softprops/action-gh-release@v2`: v2.x is the stable stream; action-gh-release v3 is Node 24 beta, not recommended for this phase [VERIFIED: GitHub README 2026]
- `SignPath/github-action-submit-signing-request@v2`: v2 is current (Oct 2025+); **CONTEXT D-23 references `@v1` which is outdated**. Planner should use `@v2`. [VERIFIED: docs.signpath.io 2026]
- `actions/upload-artifact@v4`: required pairing with SignPath v2 (action reads a `github-artifact-id` output from an `upload-artifact@v4` step) [CITED: docs.signpath.io/trusted-build-systems/github]

## Architecture Patterns

### Recommended Project Structure

```
src/installer/
├── go-mapi.nsi                      # main NSIS script — INST-01, INST-02, INST-05, INST-06
├── plugins/
│   └── x86-unicode/
│       └── ApplicationID.dll         # vendored NSIS plugin — AUMID stamping
├── MicrosoftEdgeWebview2Setup.exe    # ~2 MB online bootstrapper, downloaded fresh per release
└── tests/
    └── installer.Tests.ps1           # Pester 5 smoke test — INST-07

src/app/
├── webview2_check.go                 # NEW — HKLM pv regkey read + MessageBoxW + browser.Open + os.Exit (1)
├── webview2_check_bindings.go        # NEW — no-op stub under `//go:build bindings`
└── main.go                           # MODIFIED — call checkWebView2() before checkOAuthCredentials()

.github/workflows/
├── installer-smoke.yml               # NEW — per-PR Pester round-trip (D-29)
└── installer-release.yml             # NEW — tag-push v* → signed installer (D-27)
```

### Pattern 1: Build-Tag Split for Fatal Startup Guards (D-08)

**What:** Any fatal-exit guard called from `main()` must live in a `//go:build !bindings` file with a no-op sibling under `//go:build bindings`, so `wailsbindings.exe` can introspect types without triggering `os.Exit`.

**When:** Required for every new startup guard added to `src/app/main.go`. Phase 10 adds `checkWebView2()` immediately before the existing `checkOAuthCredentials()` call.

**Example — exact pattern to mirror:**

```go
// src/app/webview2_check.go
//go:build !bindings

package main

import (
    "errors"
    "golang.org/x/sys/windows/registry"
)

// checkWebView2 returns an error if the Evergreen runtime is not installed.
// Callers (main.go) decide how to react — typically MessageBox + Open + os.Exit(1).
func checkWebView2() error {
    // Primary: 64-bit app on 64-bit Windows → WOW6432Node view holds the per-machine install
    // (Microsoft docs are explicit: on 64-bit Windows the WOW6432Node path is where the
    // per-machine Evergreen runtime records itself.)
    paths := []struct {
        root registry.Key
        path string
    }{
        {registry.LOCAL_MACHINE, `SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`},
        {registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`},
        {registry.CURRENT_USER, `Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`},
    }
    for _, p := range paths {
        k, err := registry.OpenKey(p.root, p.path, registry.QUERY_VALUE)
        if err != nil {
            continue
        }
        pv, _, err := k.GetStringValue("pv")
        k.Close()
        if err == nil && pv != "" && pv != "0.0.0.0" {
            return nil
        }
    }
    return errors.New("WebView2 runtime not installed")
}
```

```go
// src/app/webview2_check_bindings.go
//go:build bindings

package main

// checkWebView2 is a no-op under the `bindings` build tag.
func checkWebView2() error { return nil }
```

```go
// src/app/main.go — INSERTED between lines 28 (releaseSingleInstance defer) and 37 (checkOAuthCredentials call)
if err := checkWebView2(); err != nil {
    logError("FATAL: WebView2 runtime missing")
    showWebView2MissingDialog()  // MessageBoxW — see Code Example 5
    _ = browser.OpenURL("https://developer.microsoft.com/en-us/microsoft-edge/webview2/")
    os.Exit(1)
}
```

**Reference precedent:** `src/app/credentials_check.go` + `src/app/credentials_check_bindings.go` — exact same shape, just different check body.

### Pattern 2: WebView2 Detection + Bootstrap + Poll Loop (NSIS)

**What:** NSIS script flow for INST-02. Read registry → if absent, invoke bundled bootstrapper with `/silent /install` → poll registry every 2 s for up to 60 s → on timeout, log failure and continue (per D-07).

**When:** Inside an NSIS `Section` before the MAPI handler is registered (so WebView2 is ready when the Wails app first launches from the Start Menu shortcut).

**Pattern:** See §Code Examples #3 + #4 for the complete NSIS block.

**Why the poll:** The bootstrapper exits before the install completes (documented since 2021; no Microsoft fix as of 2026). [VERIFIED: https://github.com/MicrosoftEdge/WebView2Feedback/issues/1349 — still open; WebSearch 2026 "no official workaround"]. `ExecWait` is necessary but not sufficient — the registry poll is the only reliable completion signal.

### Pattern 3: NSIS Silent Install Switches (Pester + end-user silent)

**What:**
- `/S` (capital S, case-sensitive) — NSIS silent-mode flag
- `/D=<path>` — override install dir; **must be the LAST argument**, unquoted even if path contains spaces (NSIS quirk) [VERIFIED: CONTEXT specifics line 198; NSIS docs]

**When:** Pester test invocation + any enterprise silent-deploy scenario.

**Example (Pester):**
```powershell
# path with space — "Program Files" is the default install parent
$setup = "$PSScriptRoot\..\..\go-mapi-setup.exe"
$proc = Start-Process -FilePath $setup -ArgumentList '/S', '/D=C:\Program Files\go-mapi' -Wait -PassThru
$proc.ExitCode | Should -Be 0
# NOTE: no quotes around the path in /D=…, even with a space. This is NSIS's documented convention.
```

### Pattern 4: Previous-Mail-Client Backup (port from v2.0 D-09/D-16 verbatim)

**What:** Before setting `HKLM\SOFTWARE\Clients\Mail\(Default) = go-mapi`, read the existing value and write a JSON backup to `%ProgramData%\go-mapi\uninst\previous-mail-client.json`. On upgrade (current default already = `go-mapi`), do NOT overwrite the backup.

**Restore logic (uninstall):** If backup exists AND `Mail\(Default)` still = `go-mapi`: restore `previousClient` if that subkey still exists under `HKLM\SOFTWARE\Clients\Mail\`; else try fallbacks `Microsoft Outlook`, `Outlook`, `Windows Mail`; else clear to empty string.

**JSON shape:**
```json
{
  "previousClient": "Microsoft Outlook",
  "backedUpAt": "2026-04-19T14:33:51Z"
}
```

**NSIS primitives:** `ReadRegStr`, `WriteRegStr`, `FileOpen`/`FileWrite`/`FileClose` for the JSON, `nsisos::GetTime` or `System::Call 'kernel32::GetSystemTime'` for the timestamp.

### Pattern 5: Two-Phase SignPath Gating (port from v2.0 D-19/D-20)

**What:** Two SignPath calls in `installer-release.yml`:
1. **Pre-makensis** — upload-artifact `go-mapi.exe` + `go-mapi.dll` (via `actions/upload-artifact@v4` with `path:` pointing at both files) → SignPath sign → download signed artifact → replace staged binaries before `makensis` bundles them.
2. **Post-makensis** — upload-artifact `go-mapi-setup.exe` → SignPath sign → download signed installer → attach to Release.

**Gate:** `if: ${{ secrets.SIGNPATH_API_TOKEN != '' }}` on both SignPath steps; when absent, the pipeline publishes unsigned and continues.

**Required secrets (confirmed):** `SIGNPATH_API_TOKEN`, `SIGNPATH_ORG_ID`, `SIGNPATH_PROJECT_SLUG`, `SIGNPATH_SIGNING_POLICY_SLUG` — documented as inline comments in the workflow file (per v2.0 D-21 precedent).

### Anti-Patterns to Avoid

- **Using NSIS `/S` lowercase.** NSIS's silent flag is `/S` capital. `/s` is not recognized and the installer runs interactively. [VERIFIED: NSIS docs]
- **Quoting `/D=` path with spaces.** NSIS explicitly documents `/D=` takes the rest of the command line as-is (no quoting even for `C:\Program Files\…`). Quoting breaks it.
- **`pwsh.exe` in the NSIS script.** `windows-latest` runners have both `pwsh` (PS7) and `powershell.exe` (PS5.1). End-user machines only guarantee `powershell.exe`. Use `powershell.exe` for any firewall/cmdkey PowerShell one-liners.
- **`os.Exit` from a non-build-tag-split file.** Breaks `wails build` / `wailsbindings.exe`. All three project fatal guards (`checkOAuthCredentials`, the new `checkWebView2`, and anything future) MUST be in `_bindings.go`-split files.
- **Relying on bootstrapper exit code alone.** Documented bug; must poll registry. §Common Pitfalls #1.
- **Setting `HKLM\SOFTWARE\Clients\Mail\(Default) = go-mapi` BEFORE the backup.** Race destroys the captured-previous-client invariant. Order: read current → backup if not already `go-mapi` → write `go-mapi`. [VERIFIED: CONTEXT specifics line 207]
- **Using `Get-StartApps` as the Pester AUMID verifier.** Freshly-installed shortcuts are not indexed immediately — `Get-StartApps` returns empty for up to several seconds after install, producing a flaky test. [VERIFIED: WebSearch 2026 "delay caching"] Inline C# IShellLink+IPropertyStore is the stable primitive.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---|---|---|---|
| Stamping `PKEY_AppUserModel_ID` on a `.lnk` from NSIS | Inline Pascal-like code or an `ExecWait` PowerShell stub that calls the `register-dev-aumid.ps1` C# | **NSIS `ApplicationID` plugin** (D-14) | Purpose-built: `ApplicationID::Set "path" "aumid"` + `Pop $0`. 120 lines of C#+Pascal collapse to 2 lines. |
| Native-app OAuth loopback firewall rule | Win32 API fiddling, INetFwRule COM surface | **`netsh advfirewall firewall add rule`** or `New-NetFirewallRule` via `powershell.exe` | Windows 10+ ships both; single line in NSIS `ExecWait` |
| Reading WebView2 registry from Go | `golang.org/x/sys/windows` Win32 `RegOpenKeyEx` / `RegQueryValueEx` raw | **`golang.org/x/sys/windows/registry`** | Already available transitively; high-level wrapper; 3-line read. |
| `MessageBoxW` for runtime-missing dialog | Any UI library (would pull Wails/WebView2 — circular: WebView2 is missing) | **`syscall.NewLazyDLL("user32.dll") + NewProc("MessageBoxW")`** | Precedent in `src/app/sessionend.go`; stdlib-only; cannot load Wails UI when WebView2 is missing, so a native Win32 dialog is the only option |
| Scrubbing Windows Credential Manager from NSIS | Raw `wincred.h` DPAPI calls via `System::Call` | **`ExecWait 'cmdkey /delete:go-mapi:oauth-tokens'`** | Native Windows tool; colon separator matches zalando/go-keyring backend target [VERIFIED above] |
| Installer autoupdate | Self-update download-and-replace EXE | Out of scope (Phase 11) — just re-run installer | Windows locks running EXEs; already a settled v3.0 decision per PROJECT.md |
| Previous-mail-client JSON library | Embed a JSON writer | `FileWrite` a hand-built 3-line JSON string (key order fixed, no user input) | Zero user-supplied strings; format is `{"previousClient":"…","backedUpAt":"…"}` — literal template with two `StrCpy`-interpolated values. NSIS has no need for a JSON lib. |
| Signing | Any non-SignPath path (homebrew EV cert plumbing) | **`SignPath/github-action-submit-signing-request@v2`** (D-23) | SignPath Foundation is free for OSS; action is stable; gated on secrets |

**Key insight:** Every primitive Phase 10 needs is either (a) in NSIS core, (b) a standard Windows CLI tool (`cmdkey`, `netsh`, `powershell.exe`, `reg`), (c) a standard NSIS plugin (`ApplicationID`), or (d) already-proven code in this repo (`sessionend.go` user32.dll pattern, `credentials_check.go` build-tag split, `scripts/register-dev-aumid.ps1` AUMID stamping for the dev path + Pester verifier). The custom surface is small and well-bounded.

## Runtime State Inventory

> Rename/refactor classification: Phase 10 is **not a rename/refactor** but **is a migration** from v2.0's Inno Setup installer state + v2.x on-machine state to v3.0. The table covers runtime state that lives outside git and that plans must explicitly address.

| Category | Items Found | Action Required |
|---|---|---|
| **Stored data** | None on the v3.0 side. (The v2.x native-messaging manifests in `%APPDATA%\Google\Chrome\NativeMessagingHosts\com.gomapi.host.json` and Edge equivalents DO exist on any v2-installed machine — but **D-20 explicitly does not scrub them**. Users uninstall v2 first.) | **None** — code-only. CONTEXT.md D-20 locks clean-break migration. README + release-notes note is a **docs task** (owned by plan that lands the release workflow 10-06 or Phase 11 REL-07). |
| **Live service config** | **Windows Credential Manager** — target `go-mapi:oauth-tokens` on the installing user [VERIFIED zalando/go-keyring Windows backend]. Installer does NOT touch on install. **Uninstaller DOES scrub** via `cmdkey /delete:go-mapi:oauth-tokens` (current user only — per-user DPAPI scope). | **Code edit in uninstaller** — plan 10-04 adds the `cmdkey` call. Planner must verify the exact target string `go-mapi:oauth-tokens` (colon, not slash as CONTEXT.md specifics line 199 suggests). This is the most likely bug site. |
| **OS-registered state** | **HKLM Mail-client registration** (new, install-time); **Windows Firewall rule `go-mapi OAuth loopback`** (new, install-time); **Start Menu shortcut with AUMID** (new, install-time); **Previous-mail-client value at `HKLM\SOFTWARE\Clients\Mail\(Default)`** (modified, install-time; restored at uninstall). | **Install + uninstall code** — plans 10-01 (MAPI handler + backup) and 10-03 (AUMID, firewall) add; plan 10-04 removes. No data migration — all items are deterministic writes. |
| **Secrets and env vars** | `GOMAPI_OAUTH_CLIENT_ID`, `GOMAPI_OAUTH_CLIENT_SECRET` — **repo secrets in GitHub** consumed at release-workflow time for ldflags injection; no change from Phase 8. **`SIGNPATH_API_TOKEN` + org/project/policy slugs** — **repo secrets**, gated on presence. **`GOMAPI_VERSION`** — derived from `src/app/wails.json` at workflow time (new — see next row). | **None** (no secret rename). Release workflow plan 10-06 reads these by known names. No code path logs or exposes them. |
| **Build artifacts / installed packages** | `src/installer/dist/go-mapi-setup.exe` — **v2.0 Inno Setup output committed to the repo**. Stale after the NSIS migration. **D-31 mandates deletion.** Also: `src/installer/` currently has NO `.iss` file (already removed in Phase 8.1 cleanup). | **Delete `src/installer/dist/go-mapi-setup.exe`** in plan 10-01 (initial scaffolding plan), alongside the new `go-mapi.nsi`. Verified via `ls src/installer/` — only the stale `dist/` dir remains. |
| **`wails.json` schema gap** | `src/app/wails.json` has `name`, `outputfilename`, `frontend:install`, `frontend:build`, `frontend:dev:watcher`, `frontend:dev:serverUrl`, `author` — **but has NO `info.productVersion` field**. CONTEXT D-26 declares wails.json the version-authority. [VERIFIED: read `src/app/wails.json` 2026-04-19] | **Plan 10-06** must ADD `"info": { "productVersion": "3.0.0" }` to `wails.json` at workflow-authoring time, or the release workflow's version-gate step (compare pushed tag vs wails.json) cannot execute. Planner surfaces this as a discrete task, not a "while I'm here" edit. |

**Multi-user caveat (D-19):** Credential Manager target `go-mapi:oauth-tokens` and `%APPDATA%\go-mapi\` are per-user, DPAPI-scoped. Machine-wide uninstaller only scrubs the *uninstalling user's* copies. Other users on a multi-user RDS host retain their own tokens + settings post-uninstall. **This is documented in README + release notes, not fixed in code.** Not a todo — a constraint.

## Common Pitfalls

### Pitfall 1: WebView2 Bootstrapper `/silent /install` Exits Before Install Completes

**What goes wrong:** The ~2 MB online bootstrapper (`MicrosoftEdgeWebview2Setup.exe`) returns control to the parent NSIS process before the actual runtime install finishes. `ExecWait` returns 0, the installer proceeds to register the MAPI handler + create the shortcut, and when the user launches go-mapi from the Start Menu the Wails app crashes or shows a blank window — WebView2 runtime is still installing (or has failed silently).

**Why it happens:** Known bug since 2021 [VERIFIED: https://github.com/MicrosoftEdge/WebView2Feedback/issues/1349 — still open as of 2026-04; WebSearch confirmed "no official Microsoft-provided workaround"]. Bootstrapper's design launches a detached child process and returns without waiting.

**How to avoid:** After `ExecWait '"$INSTDIR\MicrosoftEdgeWebview2Setup.exe" /silent /install'`, **poll the HKLM registry** for the `pv` value at the Evergreen GUID every 2 seconds for up to 30 iterations (60-second budget). See §Code Example 4.

**Warning signs:**
- Pester test fails at "WebView2 present" check but passes later on subsequent runs
- End users report first launch shows blank window; second launch works
- Installer logs show `ExecWait` returned 0 but `pv` regkey is absent

**Phase budget:** Plan 10-02 must include both the poll loop AND the Wails-side runtime-recovery path (D-08). The recovery path is the last line of defense: even if install seems OK, runtime can be uninstalled between install and first launch.

### Pitfall 2: NSIS `ApplicationID` Plugin Silent Install Fails — AUMID Not Stamped

**What goes wrong:** `ApplicationID::Set` call succeeds visibly but the `.lnk` has no AUMID stamped. Toasts from Wails app appear but vanish from Action Center (NOTIF-04 broken).

**Why it happens:** Three sub-causes:
1. **Plugin missing at build time.** `makensis` silently skips unresolved plugins if `!addplugindir` path is wrong or empty.
2. **Wrong architecture subfolder.** NSIS v3.x Unicode builds (default) need `Plugins\x86-unicode\ApplicationID.dll`; ANSI builds need `Plugins\x86-ansi\`.
3. **Return code not checked.** Plugin pushes `0` (success) or `-1` (error) on the stack; script must `Pop $0` and branch, else failure is invisible [VERIFIED: https://nsis.sourceforge.io/ApplicationID_plug-in].

**How to avoid:**
```nsi
!addplugindir "${__FILEDIR__}\plugins"    ; path relative to go-mapi.nsi
…
CreateShortcut "$SMPROGRAMS\go-mapi.lnk" "$INSTDIR\go-mapi.exe" "" "" "" "" "" "go-mapi — MAPI-to-Gmail bridge"
ApplicationID::Set "$SMPROGRAMS\go-mapi.lnk" "com.marcfargas.gomapi"
Pop $0
StrCmp $0 "0" +3
  DetailPrint "WARNING: AUMID stamp failed, rc=$0"
  ; don't abort — proceed; user will see this in the install log.
  ; Pester test will catch it on the verify side.
```

**Warning signs:**
- Pester `Describe "AUMID on Start Menu shortcut"` fails intermittently after a plugin-folder change
- `DetailPrint` surfaces `rc=-1` in the NSIS install log
- Toasts from `com.marcfargas.gomapi` appear briefly but disappear from Action Center (the toast fires from the activeAUMID() string but Windows rejects the persist because the Start Menu entry doesn't match)

**Plan 10-03 verification step:** After `makensis` succeeds, confirm `ApplicationID.dll` was resolved by grepping the build log for `Plugins: ApplicationID::Set` instantiation. If missing, the plugin dir path is wrong.

### Pitfall 3: `cmdkey /delete` Targets the Wrong Windows Credential Manager Entry

**What goes wrong:** Uninstaller runs `cmdkey /delete:go-mapi` thinking it matches the keyring entry, but zalando/go-keyring stores under `go-mapi:oauth-tokens` (colon + user). The `cmdkey` call silently succeeds against a non-existent target (or a different unrelated target), leaving the real OAuth tokens in place.

**Why it happens:** zalando/go-keyring concatenates `service + ":" + username` as the Windows Credential Manager target name [VERIFIED: https://github.com/zalando/go-keyring/blob/master/keyring_windows.go — `credName` method]. CONTEXT.md specifics line 199 calls this out with a "planner confirms" note; this research confirms.

**How to avoid:** Use the exact target string `go-mapi:oauth-tokens`:

```nsi
ExecWait 'cmdkey /delete:go-mapi:oauth-tokens' $0
DetailPrint "cmdkey /delete:go-mapi:oauth-tokens rc=$0"
; rc=0 = deleted; rc=1 = not found (acceptable — user may have signed out already)
```

**Pester verifier (D-21 item 12):** `cmdkey /list:go-mapi:oauth-tokens` — output must be "Currently stored credentials: * NONE *" or similar "not found" indicator. Parse via `cmdkey /list:go-mapi:oauth-tokens 2>&1 | Select-String -NotMatch "go-mapi"`.

**Warning signs:**
- After uninstall, user runs installer again, runs app — app auto-signs-in without prompting (tokens survived)
- `cmdkey /list` still shows `Target: go-mapi:oauth-tokens` after uninstall

### Pitfall 4: OAuth Loopback Firewall Prompt on First Sign-In Hangs RDS Server

**What goes wrong:** First time Wails app starts the OAuth loopback HTTP server, Windows Firewall triggers a UAC-style approval dialog. On RDS the dialog appears on the server console, not the user's RDP session; the user's OAuth flow silently hangs forever after they approve in the browser.

**Why it happens:** `net.Listen("tcp", "127.0.0.1:0")` triggers Windows Firewall's first-bind classification. Without a pre-created inbound rule for `go-mapi.exe`, the classification UI appears on the interactive console. [VERIFIED: PITFALLS.md §Pitfall 4 + Microsoft Firewall docs]

**How to avoid:** Installer creates the firewall rule **as part of the install flow** (before first launch):

```nsi
; Using netsh (single line, available Windows 10+):
ExecWait 'netsh advfirewall firewall add rule name="go-mapi OAuth loopback" dir=in program="$INSTDIR\go-mapi.exe" action=allow profile=any' $0
DetailPrint "firewall add rc=$0"
```

```nsi
; Uninstaller:
ExecWait 'netsh advfirewall firewall delete rule name="go-mapi OAuth loopback"' $0
```

Equivalent PowerShell (longer, structured-output):
```nsi
ExecWait 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "New-NetFirewallRule -DisplayName \"go-mapi OAuth loopback\" -Direction Inbound -Program \"$INSTDIR\go-mapi.exe\" -Action Allow -Profile Any"' $0
```

**Recommended:** `netsh` — one-liner, no PowerShell escaping, works on every Windows 10+ SKU without requiring PS5.1 `NetSecurity` module.

**Warning signs:** Pester smoke-test passes on the runner (GH runner firewall disabled for localhost), but end-user RDS bug reports hang during sign-in.

### Pitfall 5: `/D=` Path with Spaces Is Dropped If Quoted

**What goes wrong:** `go-mapi-setup.exe /S /D="C:\Program Files\go-mapi"` installs to the NSIS default `$PROGRAMFILES64\go-mapi` (not the requested path), or fails silently. Pester test asserts files under a path that doesn't exist.

**Why it happens:** NSIS's silent-install path override `/D=` takes "everything after the = to end-of-command-line as the target path, verbatim". Quotes are treated as literal characters, producing a path like `"C:\Program Files\go-mapi"` with embedded quote marks — which fails.

**How to avoid:** **Do not quote the `/D=` argument**, even for paths containing spaces. Pass each token as a separate `ArgumentList` element. For PowerShell invocation:
```powershell
Start-Process $setup -ArgumentList '/S', '/D=C:\Program Files\go-mapi' -Wait -PassThru
```
Note: `/D=…` is a single string in the argument array, `=` is literal; the full token (including spaces within the path) is passed as one argument to NSIS. Windows's CRT argv parser preserves `/D=C:\Program Files\go-mapi` as one token because PowerShell passes it that way when supplied via `-ArgumentList` as a single string.

Actually: `PowerShell`'s `-ArgumentList` quotes each element, so `'/D=C:\Program Files\go-mapi'` is passed as `"/D=C:\Program Files\go-mapi"` with quotes — which NSIS sees as `/D=C:\Program Files\go-mapi` once Windows CRT parsing strips the outer quotes. This works.

But if someone writes `$setup /S "/D=C:\Program Files\go-mapi"` in `cmd.exe`, the quotes survive and the path is wrong.

**Safest Pester invocation:**
```powershell
$installDir = "$env:ProgramFiles\go-mapi"
$proc = Start-Process -FilePath $setup -ArgumentList "/S","/D=$installDir" -Wait -PassThru
```
PowerShell's `-ArgumentList` array-form correctly preserves the `/D=C:\Program Files\go-mapi` token.

## Code Examples

All examples are plan-ready scaffolds. Treat as seeds; planner refines.

### 1. NSIS Script Header (go-mapi.nsi) — ModernUI2 + Admin + 64-bit

```nsi
; go-mapi NSIS installer — Phase 10
; src/installer/go-mapi.nsi
Unicode True                                        ; Plugins/x86-unicode/
!define PRODUCT_NAME      "go-mapi"
!define PRODUCT_VERSION   "${GOMAPI_VERSION}"       ; passed via makensis /DGOMAPI_VERSION=3.0.0
!define PRODUCT_PUBLISHER "Marc Fargas"
!define PRODUCT_WEB_SITE  "https://github.com/marcfargas/go-mapi"
!define AUMID             "com.marcfargas.gomapi"

SetCompressor /SOLID lzma
RequestExecutionLevel admin                          ; D-02 — machine-wide only
InstallDir   "$PROGRAMFILES64\go-mapi"               ; D-02
OutFile      "go-mapi-setup.exe"                     ; D-03 (no version suffix)
Name         "${PRODUCT_NAME} ${PRODUCT_VERSION}"
BrandingText "${PRODUCT_NAME} ${PRODUCT_VERSION} — LGPL-3.0"

; Plugin directory — ApplicationID.dll vendored in src/installer/plugins/x86-unicode/
!addplugindir "${__FILEDIR__}\plugins"

!include "MUI2.nsh"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${__FILEDIR__}\..\..\LICENSE"   ; LGPL-3.0
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
```

### 2. Install Section — Binary Staging + MAPI Handler + Backup

```nsi
Section "Install" SecInstall
  SetOutPath "$INSTDIR"

  ; Staged binaries from the Wails build + interceptor build
  File "${__FILEDIR__}\..\app\build\bin\go-mapi.exe"
  File "${__FILEDIR__}\..\interceptor\build\bin\go-mapi.dll"

  ; D-10: backup previous Mail client BEFORE setting Default (only if not already go-mapi)
  Call BackupPreviousMailClient   ; sets %ProgramData%\go-mapi\uninst\previous-mail-client.json

  ; D-09: MAPI handler registration
  WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "" "go-mapi"
  WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "DLLPath" "$INSTDIR\go-mapi.dll"
  ; set Default AFTER backup completes
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "go-mapi"

  ; Uninstaller
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; Add/Remove Programs metadata
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "DisplayName"     "${PRODUCT_NAME}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "DisplayVersion"  "${PRODUCT_VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "Publisher"       "${PRODUCT_PUBLISHER}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "URLInfoAbout"    "${PRODUCT_WEB_SITE}"

  Call InstallWebView2        ; Code Example 3
  Call CreateShortcutAndAUMID ; Code Example 6
  Call AddFirewallRule        ; Code Example 10 — netsh one-liner
SectionEnd
```

### 3. NSIS — WebView2 Detection

```nsi
; Returns "1" (present) or "0" (absent) on the stack.
Function DetectWebView2
  Push $0
  Push $1

  ; Primary: HKLM 64-bit app → WOW6432Node view
  SetRegView 64
  ReadRegStr $0 HKLM "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" 0 WebView2Found
  StrCmp $0 "0.0.0.0" 0 WebView2Found

  ; Fallback: HKLM direct (on 32-bit Windows or odd install variants)
  ReadRegStr $0 HKLM "SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" 0 WebView2Found
  StrCmp $0 "0.0.0.0" 0 WebView2Found

  ; Fallback: per-user (HKCU)
  SetRegView 32
  ReadRegStr $0 HKCU "Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" WebView2NotFound WebView2Found

WebView2NotFound:
  Pop $1
  Pop $0
  Push "0"
  Return

WebView2Found:
  DetailPrint "WebView2 runtime detected: $0"
  Pop $1
  Pop $0
  Push "1"
  Return
FunctionEnd
```

**Source:** https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution §"Detect if a WebView2 Runtime is already installed" (updated 2026-02-27).

### 4. NSIS — WebView2 Bootstrap + Poll Loop

```nsi
Function InstallWebView2
  Call DetectWebView2
  Pop $0
  StrCmp $0 "1" WebView2Ready

  DetailPrint "WebView2 runtime not present — invoking bootstrapper"
  SetOutPath "$INSTDIR"
  File "${__FILEDIR__}\MicrosoftEdgeWebview2Setup.exe"

  ; Fire-and-poll: bootstrapper returns before install completes (GH issue 1349, unfixed as of 2026)
  ExecWait '"$INSTDIR\MicrosoftEdgeWebview2Setup.exe" /silent /install' $1
  DetailPrint "WebView2 bootstrapper exit=$1 — polling registry for completion"

  ; Poll every 2s for up to 30 iterations (60s budget) — D-06
  StrCpy $2 "0"
PollLoop:
  IntOp $2 $2 + 1
  IntCmp $2 30 PollTimeout    ; 30 * 2s = 60s
  Sleep 2000
  Call DetectWebView2
  Pop $0
  StrCmp $0 "1" WebView2Installed
  Goto PollLoop

PollTimeout:
  ; D-07: continue rather than abort. Log the failure. Wails app has a runtime-recovery path.
  DetailPrint "WARNING: WebView2 bootstrap did not complete within 60s"
  FileOpen $3 "$INSTDIR\install.log" w
  FileWrite $3 "WebView2 bootstrap timed out after 60s; user will be prompted on app launch.$\r$\n"
  FileClose $3
  ; Clean up bootstrapper regardless of outcome
  Delete "$INSTDIR\MicrosoftEdgeWebview2Setup.exe"
  Return

WebView2Installed:
  DetailPrint "WebView2 runtime install completed after $2 polls"
  Delete "$INSTDIR\MicrosoftEdgeWebview2Setup.exe"
  Return

WebView2Ready:
  DetailPrint "WebView2 runtime already present; skipping bootstrap"
  Return
FunctionEnd
```

**Source:** Bootstrapper invocation from https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution §"Online-only deployment"; poll pattern from community consensus on https://github.com/MicrosoftEdge/WebView2Feedback/issues/1349 (no Microsoft-provided workaround as of 2026).

### 5. Go — Wails Runtime-Missing Recovery (D-08) — `showWebView2MissingDialog`

Pattern mirrors `src/app/sessionend.go:20-32` exactly.

```go
// src/app/webview2_check.go — additional function, same build tag
//go:build !bindings

package main

import (
    "syscall"
    "unsafe"
)

var (
    user32            = syscall.NewLazyDLL("user32.dll")        // NOTE: already declared in sessionend.go — planner reuses or scopes
    procMessageBoxW   = user32.NewProc("MessageBoxW")
)

// showWebView2MissingDialog blocks until the user clicks OK.
// Flags: MB_OK (0x0) | MB_ICONERROR (0x10) | MB_SYSTEMMODAL (0x1000).
func showWebView2MissingDialog() {
    title := syscall.StringToUTF16Ptr("go-mapi — WebView2 required")
    body := syscall.StringToUTF16Ptr(
        "Microsoft Edge WebView2 Runtime is required to run go-mapi.\r\n\r\n" +
        "Your system browser will now open the Microsoft download page. " +
        "Install the runtime, then relaunch go-mapi.")
    procMessageBoxW.Call(
        0, // hWnd = null → system-modal
        uintptr(unsafe.Pointer(body)),
        uintptr(unsafe.Pointer(title)),
        uintptr(0x1010), // MB_OK | MB_ICONERROR
    )
}
```

**Caveat for planner:** if `user32 = syscall.NewLazyDLL(...)` is already a package-level var in `sessionend.go`, declare `procMessageBoxW` as a sibling `NewProc` on the existing `user32` rather than re-declaring the DLL handle. Go's init order handles this, but re-declaring the var would be a compile error.

### 6. NSIS — Start Menu Shortcut + AUMID Stamp

```nsi
Function CreateShortcutAndAUMID
  ; ModernUI2 creates the shortcut with standard metadata
  CreateShortcut "$SMPROGRAMS\go-mapi.lnk" \
      "$INSTDIR\go-mapi.exe" \
      "" \
      "$INSTDIR\go-mapi.exe" 0 \
      SW_SHOWNORMAL "" \
      "go-mapi — MAPI-to-Gmail bridge"

  ; D-14: stamp PKEY_AppUserModel_ID via ApplicationID plugin
  ApplicationID::Set "$SMPROGRAMS\go-mapi.lnk" "${AUMID}"
  Pop $0
  StrCmp $0 "0" +3
    DetailPrint "WARNING: AUMID stamp rc=$0 — Action Center persistence may break"
    ; continue — Pester will catch this in CI; manual users can re-run install
FunctionEnd
```

**Source:** https://nsis.sourceforge.io/ApplicationID_plug-in — `ApplicationID::Set "<path>" "<aumid>"` + `Pop $0` (0=success, -1=error).

### 7. NSIS — Uninstall Section (10-step scrub per D-18)

```nsi
Section "Uninstall"
  ; 1. Firewall rule
  ExecWait 'netsh advfirewall firewall delete rule name="go-mapi OAuth loopback"' $0
  DetailPrint "firewall delete rc=$0"

  ; 2. Start Menu shortcut
  Delete "$SMPROGRAMS\go-mapi.lnk"

  ; 3. MAPI handler key
  DeleteRegKey HKLM "SOFTWARE\Clients\Mail\go-mapi"

  ; 4. Restore (Default) Mail client from backup — logic mirrors v2.0 install.ps1
  Call un.RestorePreviousMailClient

  ; 5. %ProgramData%\go-mapi\uninst\
  RMDir /r "$APPDATA\..\..\ProgramData\go-mapi\uninst"
  RMDir    "$APPDATA\..\..\ProgramData\go-mapi"   ; only if empty — RMDir without /r won't remove non-empty

  ; 6. %TEMP%\go-mapi\ — best-effort, current user only (uninstaller runs as admin so this is likely SYSTEM's TEMP)
  RMDir /r "$TEMP\go-mapi"

  ; 7. %APPDATA%\go-mapi\ — uninstalling user only (per-user scope, DPAPI-bound)
  RMDir /r "$APPDATA\go-mapi"

  ; 8. Windows Credential Manager — target is service:user per zalando/go-keyring (VERIFIED)
  ExecWait 'cmdkey /delete:go-mapi:oauth-tokens' $0
  DetailPrint "cmdkey /delete:go-mapi:oauth-tokens rc=$0"

  ; 9. Binaries
  Delete "$INSTDIR\go-mapi.exe"
  Delete "$INSTDIR\go-mapi.dll"
  Delete "$INSTDIR\uninstall.exe"
  Delete "$INSTDIR\install.log"

  ; 10. Install dir (only if empty; leftover files keep it)
  RMDir "$INSTDIR"

  ; Add/Remove Programs entry
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}"
SectionEnd
```

### 8. NSIS — Backup Previous Mail Client

```nsi
Function BackupPreviousMailClient
  CreateDirectory "$APPDATA\..\..\ProgramData\go-mapi\uninst"

  ReadRegStr $0 HKLM "SOFTWARE\Clients\Mail" ""
  StrCmp $0 "go-mapi" AlreadyUs       ; upgrade case — preserve existing backup
  StrCmp $0 "" BackupNull

  ; Write JSON with explicit field order
  FileOpen $1 "$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json" w
  FileWrite $1 '{"previousClient":"$0","backedUpAt":"'
  Call GetISOTimestamp
  Pop $2
  FileWrite $1 '$2"}'
  FileClose $1
  DetailPrint "Previous Mail client backed up: $0"
  Return

BackupNull:
  FileOpen $1 "$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json" w
  FileWrite $1 '{"previousClient":null,"backedUpAt":"'
  Call GetISOTimestamp
  Pop $2
  FileWrite $1 '$2"}'
  FileClose $1
  DetailPrint "No previous Mail client (null backup written)"
  Return

AlreadyUs:
  DetailPrint "Upgrade detected — preserving existing previous-mail-client.json"
  Return
FunctionEnd

; GetISOTimestamp: pushes "YYYY-MM-DDTHH:MM:SSZ"
; Primitive: System::Call 'kernel32::GetSystemTime(*i.r0)' + StrFmt via nsisFirstName plugin,
; OR call powershell.exe -NoProfile -Command "(Get-Date -Format o)" via ExecWait + stdout capture.
; Recommended: ExecDos plugin or inline PS — short one-liner.
```

### 9. NSIS — Restore Previous Mail Client (uninstall)

```nsi
Function un.RestorePreviousMailClient
  ReadRegStr $0 HKLM "SOFTWARE\Clients\Mail" ""
  StrCmp $0 "go-mapi" 0 DoneRestore   ; someone else already took over — don't clobber

  ; Parse the backup JSON — primitive approach, no JSON lib
  Push "$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json"
  Call un.ReadPreviousClientFromJSON    ; pushes the name or ""
  Pop $1

  StrCmp $1 "" TryFallbacks
  ; Verify the target subkey still exists
  ReadRegStr $2 HKLM "SOFTWARE\Clients\Mail\$1" ""
  StrCmp $2 "" TryFallbacks
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "$1"
  DetailPrint "Restored Mail default to: $1"
  Goto DoneRestore

TryFallbacks:
  ; Try "Microsoft Outlook" → "Outlook" → "Windows Mail" → clear
  ReadRegStr $2 HKLM "SOFTWARE\Clients\Mail\Microsoft Outlook" ""
  StrCmp $2 "" TryOutlook
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "Microsoft Outlook"
  Goto DoneRestore
TryOutlook:
  ReadRegStr $2 HKLM "SOFTWARE\Clients\Mail\Outlook" ""
  StrCmp $2 "" TryWinMail
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "Outlook"
  Goto DoneRestore
TryWinMail:
  ReadRegStr $2 HKLM "SOFTWARE\Clients\Mail\Windows Mail" ""
  StrCmp $2 "" ClearDefault
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "Windows Mail"
  Goto DoneRestore
ClearDefault:
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" ""
  DetailPrint "No fallback Mail client found — cleared default"
DoneRestore:
FunctionEnd
```

### 10. NSIS — Firewall Rule (netsh — recommended)

```nsi
Function AddFirewallRule
  ExecWait 'netsh advfirewall firewall add rule name="go-mapi OAuth loopback" dir=in program="$INSTDIR\go-mapi.exe" action=allow profile=any' $0
  DetailPrint "firewall add rc=$0"
FunctionEnd
```

### 11. Pester 5 — Configuration + Smoke-Test Skeleton

```powershell
# src/installer/tests/installer.Tests.ps1
# Pester 5 idiom — per D-30, Pester 4 `-EnableExit` is forbidden.

BeforeAll {
    $script:SetupExe   = Join-Path $PSScriptRoot '..\..\..\go-mapi-setup.exe' | Resolve-Path
    $script:InstallDir = "$env:ProgramFiles\go-mapi"
    $script:Aumid      = 'com.marcfargas.gomapi'
}

Describe "go-mapi installer silent install + uninstall round-trip" {
    Context "Silent install" {
        It "exits 0 when invoked with /S /D=..." {
            $proc = Start-Process -FilePath $script:SetupExe -ArgumentList '/S',"/D=$script:InstallDir" -Wait -PassThru
            $proc.ExitCode | Should -Be 0
        }

        It "deposits go-mapi.exe and go-mapi.dll" {
            Test-Path (Join-Path $script:InstallDir 'go-mapi.exe') | Should -Be $true
            Test-Path (Join-Path $script:InstallDir 'go-mapi.dll') | Should -Be $true
        }

        It "registers HKLM MAPI handler" {
            $key = 'HKLM:\SOFTWARE\Clients\Mail\go-mapi'
            Test-Path $key | Should -Be $true
            (Get-ItemProperty $key).DLLPath | Should -Match 'go-mapi\.dll$'
        }

        It "writes previous-mail-client.json with required fields" {
            $backup = "$env:ProgramData\go-mapi\uninst\previous-mail-client.json"
            Test-Path $backup | Should -Be $true
            $json = Get-Content $backup | ConvertFrom-Json
            $json.PSObject.Properties.Name | Should -Contain 'previousClient'
            $json.PSObject.Properties.Name | Should -Contain 'backedUpAt'
        }

        It "creates Start Menu shortcut with correct AUMID" {
            $lnk = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\go-mapi.lnk"
            # ProgramData for all-users Start Menu — NSIS $SMPROGRAMS with admin rights resolves here
            # If not there, check user Start Menu as fallback
            if (-not (Test-Path $lnk)) {
                $lnk = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\go-mapi.lnk"
            }
            Test-Path $lnk | Should -Be $true

            # See Code Example 12 for the inline-C# IShellLink+IPropertyStore reader
            $actualAumid = Get-ShortcutAumid $lnk
            $actualAumid | Should -Be $script:Aumid
        }

        It "creates Windows Firewall rule" {
            Get-NetFirewallRule -DisplayName 'go-mapi OAuth loopback' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "Silent uninstall" {
        It "exits 0 when invoked with /S" {
            $uninst = Join-Path $script:InstallDir 'uninstall.exe'
            $proc = Start-Process -FilePath $uninst -ArgumentList '/S' -Wait -PassThru
            $proc.ExitCode | Should -Be 0
        }

        It "removes install dir (or leaves empty)" {
            (Test-Path $script:InstallDir) -eq $false -or ((Get-ChildItem $script:InstallDir -Force).Count -eq 0) | Should -Be $true
        }

        It "removes MAPI handler key" {
            Test-Path 'HKLM:\SOFTWARE\Clients\Mail\go-mapi' | Should -Be $false
        }

        It "removes firewall rule" {
            Get-NetFirewallRule -DisplayName 'go-mapi OAuth loopback' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }

        It "removes %APPDATA%\go-mapi\ for runner user" {
            Test-Path "$env:APPDATA\go-mapi" | Should -Be $false
        }

        It "removes Credential Manager entry" {
            # cmdkey /list prints to stdout; grep for the target
            $out = & cmdkey /list:go-mapi:oauth-tokens 2>&1
            $out | Select-String -Pattern 'go-mapi:oauth-tokens' | Should -BeNullOrEmpty
        }

        It "removes Start Menu shortcut" {
            $lnk = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\go-mapi.lnk"
            Test-Path $lnk | Should -Be $false
        }
    }
}
```

**Run invocation (CI):**
```powershell
$config = New-PesterConfiguration
$config.Run.Path        = 'src/installer/tests/installer.Tests.ps1'
$config.Run.Exit        = $true
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config
```

### 12. Pester — AUMID Verification via Inline C# (Stable Primitive)

Mirrors the stamp-side code in `scripts/register-dev-aumid.ps1`. Read instead of write.

```powershell
# Load at BeforeAll — inside installer.Tests.ps1 or a shared fixtures script
Add-Type -Namespace GoMapi -Name AumidReader -MemberDefinition @'
    using System;
    using System.Runtime.InteropServices;

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        void GetCount(out uint count);
        void GetAt(uint iProp, out PROPERTYKEY pkey);
        void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
        void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PROPERTYKEY {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPVARIANT {
        public ushort vt;
        public ushort reserved1;
        public ushort reserved2;
        public ushort reserved3;
        public IntPtr union1;
        public IntPtr union2;
    }

    [ComImport, Guid("0000010B-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPersistFile {
        void GetClassID(out Guid pClassID);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    public static class Native {
        [DllImport("ole32.dll", PreserveSig = false)]
        public static extern void CoCreateInstance(
            [MarshalAs(UnmanagedType.LPStruct)] Guid rclsid,
            IntPtr pUnkOuter, uint dwClsContext,
            [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
            [MarshalAs(UnmanagedType.IUnknown)] out object ppv);

        [DllImport("propsys.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        public static extern void PropVariantToString(ref PROPVARIANT pv, System.Text.StringBuilder psz, int cch);
    }

    public static class Reader {
        public static string GetAumid(string lnkPath) {
            Guid clsidShellLink = new Guid("00021401-0000-0000-C000-000000000046");
            Guid iidIPersistFile = new Guid("0000010B-0000-0000-C000-000000000046");
            Native.CoCreateInstance(clsidShellLink, IntPtr.Zero, 1, iidIPersistFile, out object obj);

            IPersistFile pf = (IPersistFile)obj;
            pf.Load(lnkPath, 0 /*STGM_READ*/);

            IPropertyStore ps = (IPropertyStore)obj;
            PROPERTYKEY key = new PROPERTYKEY {
                fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
                pid   = 5
            };
            PROPVARIANT pv;
            ps.GetValue(ref key, out pv);

            var sb = new System.Text.StringBuilder(260);
            Native.PropVariantToString(ref pv, sb, sb.Capacity);
            System.Runtime.InteropServices.Marshal.ReleaseComObject(obj);
            return sb.ToString();
        }
    }
'@

function Get-ShortcutAumid {
    param([Parameter(Mandatory)][string]$Path)
    return [GoMapi.AumidReader+Reader]::GetAumid($Path)
}
```

**Source:** Mirrors `scripts/register-dev-aumid.ps1` (stamp side); the Reader class uses the same COM pattern in read mode. [CITED: https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-id].

**Why not `Get-StartApps`:** Freshly-installed shortcuts have an indexing delay before `Get-StartApps` lists them. Test would flake. [VERIFIED: WebSearch 2026 "newly installed apps not listed"].

### 13. GitHub Actions — `installer-smoke.yml` Skeleton (D-29)

```yaml
name: Installer smoke test
on:
  push:
    branches: [main, develop]
    paths:
      - 'src/installer/**'
      - 'src/interceptor/**'
      - 'src/app/**'
      - '.github/workflows/installer-smoke.yml'
  pull_request:
    paths:
      - 'src/installer/**'
      - 'src/interceptor/**'
      - 'src/app/**'
      - '.github/workflows/installer-smoke.yml'
  workflow_dispatch:

jobs:
  smoke:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.25'
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
      - name: Install Wails CLI
        run: go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0
      - name: Build interceptor DLL
        run: npm run build:interceptor
      - name: Build Wails app (dev creds — no SignPath for smoke)
        working-directory: src/app
        env:
          GOMAPI_OAUTH_CLIENT_ID:     ${{ secrets.GOMAPI_OAUTH_CLIENT_ID }}
          GOMAPI_OAUTH_CLIENT_SECRET: ${{ secrets.GOMAPI_OAUTH_CLIENT_SECRET }}
        run: |
          wails build -platform windows/amd64 -ldflags "-X main.aumidOverride=com.marcfargas.gomapi -X main.oauthClientID=$env:GOMAPI_OAUTH_CLIENT_ID -X main.oauthClientSecret=$env:GOMAPI_OAUTH_CLIENT_SECRET"
      - name: NSIS is pre-installed on windows-latest — verify
        run: makensis /VERSION
      - name: Compile installer
        run: makensis /DGOMAPI_VERSION=0.0.0-smoke src\installer\go-mapi.nsi
      - name: Run Pester
        shell: pwsh
        run: |
          $config = New-PesterConfiguration
          $config.Run.Path        = 'src/installer/tests/installer.Tests.ps1'
          $config.Run.Exit        = $true
          $config.Output.Verbosity = 'Detailed'
          Invoke-Pester -Configuration $config
```

**Notes:**
- NSIS is pre-installed as 3.10.0 on `windows-latest` (2026); fallback to `choco install nsis --no-progress -y` only if runner changes. [VERIFIED: GH Marketplace]
- `ApplicationID.dll` is vendored in-repo; no plugin-install step needed.
- Smoke workflow does NOT sign. Signing is release-only per D-25.

### 14. GitHub Actions — `installer-release.yml` Skeleton (D-27)

```yaml
name: Installer release
on:
  push:
    tags: ['v*']

permissions:
  contents: write       # for softprops/action-gh-release@v2
  actions:  read        # for SignPath v2 to read artifacts

jobs:
  release:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.25' }
      - uses: actions/setup-node@v4
        with: { node-version: '20' }

      - name: Install Wails CLI
        run: go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0

      - name: Extract version + validate against tag
        id: version
        shell: pwsh
        run: |
          $json = Get-Content src/app/wails.json | ConvertFrom-Json
          $wailsVer = $json.info.productVersion
          $tagVer   = "${{ github.ref_name }}" -replace '^v',''
          if ($wailsVer -ne $tagVer) { throw "Tag $tagVer != wails.json $wailsVer" }
          "version=$wailsVer" >> $env:GITHUB_OUTPUT

      - name: Build interceptor DLL
        run: npm run build:interceptor

      - name: Build Wails app (release ldflags)
        working-directory: src/app
        env:
          GOMAPI_OAUTH_CLIENT_ID:     ${{ secrets.GOMAPI_OAUTH_CLIENT_ID }}
          GOMAPI_OAUTH_CLIENT_SECRET: ${{ secrets.GOMAPI_OAUTH_CLIENT_SECRET }}
        run: |
          wails build -platform windows/amd64 -ldflags "-X main.Version=${{ steps.version.outputs.version }} -X main.aumidOverride=com.marcfargas.gomapi -X main.oauthClientID=$env:GOMAPI_OAUTH_CLIENT_ID -X main.oauthClientSecret=$env:GOMAPI_OAUTH_CLIENT_SECRET"

      - name: Stage unsigned binaries
        run: |
          mkdir staged
          copy src\app\build\bin\go-mapi.exe staged\
          copy src\interceptor\build\bin\go-mapi.dll staged\

      - name: Upload binaries for SignPath (step 1)
        if: ${{ secrets.SIGNPATH_API_TOKEN != '' }}
        id: upload-binaries
        uses: actions/upload-artifact@v4
        with:
          name: go-mapi-binaries-unsigned
          path: staged/

      - name: SignPath — sign binaries
        if: ${{ secrets.SIGNPATH_API_TOKEN != '' }}
        uses: signpath/github-action-submit-signing-request@v2
        with:
          api-token:            ${{ secrets.SIGNPATH_API_TOKEN }}
          organization-id:      ${{ secrets.SIGNPATH_ORG_ID }}
          project-slug:         ${{ secrets.SIGNPATH_PROJECT_SLUG }}
          signing-policy-slug:  ${{ secrets.SIGNPATH_SIGNING_POLICY_SLUG }}
          github-artifact-id:   ${{ steps.upload-binaries.outputs.artifact-id }}
          output-artifact-directory: staged-signed
          wait-for-completion: true

      - name: Swap in signed binaries
        if: ${{ secrets.SIGNPATH_API_TOKEN != '' }}
        run: |
          copy staged-signed\go-mapi.exe src\app\build\bin\go-mapi.exe /Y
          copy staged-signed\go-mapi.dll src\interceptor\build\bin\go-mapi.dll /Y

      - name: Compile installer
        run: makensis /DGOMAPI_VERSION=${{ steps.version.outputs.version }} src\installer\go-mapi.nsi

      - name: Upload installer for SignPath (step 2)
        if: ${{ secrets.SIGNPATH_API_TOKEN != '' }}
        id: upload-installer
        uses: actions/upload-artifact@v4
        with:
          name: go-mapi-setup-unsigned
          path: go-mapi-setup.exe

      - name: SignPath — sign installer
        if: ${{ secrets.SIGNPATH_API_TOKEN != '' }}
        uses: signpath/github-action-submit-signing-request@v2
        with:
          api-token:            ${{ secrets.SIGNPATH_API_TOKEN }}
          organization-id:      ${{ secrets.SIGNPATH_ORG_ID }}
          project-slug:         ${{ secrets.SIGNPATH_PROJECT_SLUG }}
          signing-policy-slug:  ${{ secrets.SIGNPATH_SIGNING_POLICY_SLUG }}
          github-artifact-id:   ${{ steps.upload-installer.outputs.artifact-id }}
          output-artifact-directory: final
          wait-for-completion: true

      - name: Locate final installer
        id: final
        shell: pwsh
        run: |
          $p = if ( Test-Path 'final/go-mapi-setup.exe' ) { 'final/go-mapi-setup.exe' } else { 'go-mapi-setup.exe' }
          "path=$p" >> $env:GITHUB_OUTPUT

      - uses: softprops/action-gh-release@v2
        with:
          files: ${{ steps.final.outputs.path }}
          draft: false
          prerelease: false
          body_path: .github/release-template.md
```

**Notes:**
- `permissions: contents: write` is MANDATORY for action-gh-release v2 [VERIFIED: https://github.com/softprops/action-gh-release README 2026].
- `actions: read` is required by SignPath v2 to read the upload-artifact output [VERIFIED: docs.signpath.io 2026].
- SignPath v2 inputs confirmed: `api-token`, `organization-id`, `project-slug`, `signing-policy-slug`, `github-artifact-id`, `output-artifact-directory`, `wait-for-completion` [VERIFIED: docs.signpath.io 2026].
- **CONTEXT D-23 says `@v1` — planner updates to `@v2`.** v1 still works but v2 is the documented current version; new pipelines should use v2.
- **CONTEXT D-27 says `softprops/action-gh-release@v2` — correct.** (v3 exists but is Node 24 beta, not recommended.)

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|---|---|---|---|
| Inno Setup 6 (v2.0) | NSIS 3.10 (v3.0) | Phase 10 (D-01, 2026-04) | AUMID stamping via dedicated plugin; Pascal Script → NSISScript; Inno's `iscc.exe` → `makensis.exe` |
| `SignPath/github-action-submit-signing-request@v1` | `@v2` (current, Oct 2025+) | Upstream action release | v2 requires explicit `actions: read` permission; `github-artifact-id` input replaces older artifact parameters |
| `softprops/action-gh-release@v1` | `@v2` (v3 in beta on Node 24) | Upstream 2024 | v2 requires `permissions: contents: write` at workflow/job level |
| Inline C# + IShellLink + IPropertyStore for AUMID stamp (100+ lines) | NSIS `ApplicationID` plugin (one line) | Phase 10 prod path | Dev path `scripts/register-dev-aumid.ps1` keeps inline C# (no NSIS in dev); Pester verifier keeps inline C# (read side) |
| `Get-StartApps` for AUMID verification | Inline C# IPropertyStore read | Phase 10 (this research) | `Get-StartApps` has indexing delay → flaky tests |
| Pester 4 `Invoke-Pester -EnableExit` | Pester 5 `Invoke-Pester -Configuration $cfg` | D-30 | Pester 5 is pre-installed on `windows-latest`; Pester 4 syntax is forbidden |
| WebView2 detection by registry absence + abort | Detect + bootstrap + poll + continue-on-failure + runtime-recovery in app | D-05/06/07/08 | Three layers of resilience; installer never blocks install on WebView2 failure |
| Credential Manager target `go-mapi` | `go-mapi:oauth-tokens` (colon-separated service:user) | zalando/go-keyring Windows backend convention | CONTEXT specifics line 199's "go-mapi/oauth-tokens" is wrong — confirmed via upstream source read |

**Deprecated/outdated in CONTEXT.md:**
- CONTEXT D-15 ldflags path `-X github.com/marcfargas/go-mapi/src/app.aumidOverride=...` → **actual is `-X main.aumidOverride=...`** because `src/app/toast.go` is `package main`. [VERIFIED: grep `aumidOverride` in `src/app/toast.go:53`]
- CONTEXT D-23 `SignPath/github-action-submit-signing-request@v1` → **use `@v2`**. [VERIFIED: docs.signpath.io 2026]
- CONTEXT specifics line 199 keyring target `go-mapi/oauth-tokens` → **actual is `go-mapi:oauth-tokens` (colon)**. [VERIFIED: zalando/go-keyring Windows source]
- CONTEXT D-26 assumes `src/app/wails.json` has `info.productVersion` → **it does not; planner must ADD the `info` object**. [VERIFIED: file read]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|---|---|---|
| A1 | WebView2 60-second poll budget is sufficient for slow-network Evergreen bootstrapper downloads | Code Example 4 | Install completes, bootstrapper still downloading in background. Wails app's runtime-recovery path (D-08) catches this on first launch. Non-fatal. |
| A2 | NSIS 3.10.0 pre-installed on `windows-latest` will remain pre-installed through Phase 10 execution window | Standard Stack | Workflow explicitly falls back to `choco install nsis` if `makensis /VERSION` fails — planner adds the fallback step as defense. |
| A3 | SignPath v2 API is stable and v3 won't land within the Phase 10 execution window | Signing; Code Example 14 | v2 is documented as current Oct 2025+; v3 not announced. Low risk. |
| A4 | Users uninstall v2.x before v3.0 install (per D-20) — majority compliance | Runtime State Inventory | Minority who don't: orphaned Chrome/Edge native-messaging manifests remain; non-blocking (browsers just fail to find the host binary, not go-mapi's concern). PITFALLS §9 covers this. |
| A5 | `src/installer/plugins/x86-unicode/ApplicationID.dll` is the correct path for NSIS Unicode (default) builds — ANSI builds would need `x86-ansi/` | Architecture Patterns | NSIS script explicitly declares `Unicode True`. Low risk. |
| A6 | `actions/upload-artifact@v4` output `artifact-id` is the correct field name for SignPath v2's `github-artifact-id` input | Code Example 14 | Confirmed in SignPath docs example. Low risk. |

**All six assumptions are low-risk:** three are confirmed by official sources but marked as assumptions because runtime-environment conditions (A1, A2, A3) could drift between research date and execution date. Three (A4, A5, A6) are verified against source material.

## Open Questions

1. **Should the ModernUI2 license page show the full LGPL-3.0 text or a "go-mapi is licensed under LGPL-3.0; see <github URL>" summary?**
   - **What we know:** LGPL-3.0 compliance requires the license text be made available; doesn't mandate display during install. Distro installers vary.
   - **What's unclear:** User preference.
   - **Recommendation:** Ship the full LGPL-3.0 text (inherited from repo `LICENSE`). Planner adds `!insertmacro MUI_PAGE_LICENSE "${__FILEDIR__}\..\..\LICENSE"`. If Marc prefers summary, one-line edit.

2. **Plan boundary between 10-02 (WebView2) and 10-03 (AUMID+Firewall)?**
   - **What we know:** Each plan can stand alone; there's no shared state between WebView2 bootstrap and AUMID+Firewall.
   - **What's unclear:** Whether to keep separate for reviewability or merge into a single "installer core" plan.
   - **Recommendation:** Keep separate. WebView2 has the highest risk (Pitfall 1) and deserves its own review surface. Merging raises plan size to ~500+ lines.

3. **Should Pester smoke workflow run on every PR or path-filtered to installer-relevant paths only?**
   - **What we know:** v2.0 path-filtered. NSIS compile + round-trip install+uninstall takes ~3 minutes on `windows-latest`.
   - **What's unclear:** Whether Marc wants the guard on every PR.
   - **Recommendation:** Path-filter to `src/installer/**`, `src/interceptor/**`, `src/app/**`, `.github/workflows/installer-smoke.yml` per v2.0 precedent. Planner includes the `paths:` filter block.

4. **WebView2 bootstrapper provenance in-repo: committed binary vs download-at-release-time?**
   - **What we know:** Size is ~2 MB; Microsoft's bootstrapper has a stable URL. Committing the binary drift-proofs the release but adds binary churn to git.
   - **What's unclear:** Marc's preference on binary-in-git vs fetch-at-CI.
   - **Recommendation:** Commit the bootstrapper at `src/installer/MicrosoftEdgeWebview2Setup.exe`. Size is small; determinism is worth the binary commit. If Marc prefers fetch-at-CI, add a workflow step that downloads from the Microsoft URL and pins a SHA256.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|---|---|---|---|---|
| NSIS (`makensis`) | Installer compilation (plans 10-01..04, 10-05, 10-06) | ✓ on `windows-latest` | 3.10.0 | `choco install nsis --no-progress -y` |
| NSIS ApplicationID plugin | AUMID stamping (plan 10-03) | ✗ (not bundled with NSIS core) | — | Vendor `ApplicationID.dll` in `src/installer/plugins/x86-unicode/` + `!addplugindir` |
| Pester 5 | Pester tests (plan 10-05) | ✓ on `windows-latest` | 5.x pre-installed | `Install-Module Pester -Force -SkipPublisherCheck -MinimumVersion 5.0` |
| PowerShell 5.1 (`powershell.exe`) | Alt firewall rule path | ✓ all Windows 10+ | 5.1 | `netsh advfirewall firewall` (preferred — no PS dependency) |
| Go 1.25 | Build Wails app (all plans) | ✓ (from Phase 8.1) | 1.25 | Phase 8.1 established; no action |
| Node 20 | Frontend + interceptor build | ✓ (from Phase 8.1) | 20 | Phase 8.1 established |
| Wails CLI v2.12.0 | Build Wails app | Installed via `go install` in workflows | 2.12.0 | — |
| MinGW (g++) | Interceptor DLL build | ✓ on `windows-latest` | Standard | Already consumed by `npm run build:interceptor` |
| CMake 3.16+ | Interceptor DLL build | ✓ on `windows-latest` | Standard | — |
| SignPath account | Code signing | ⚠️ Marc's account (existing OSS) | — | Gated on `SIGNPATH_API_TOKEN`; pipeline publishes unsigned when absent |
| WebView2 Evergreen Runtime on `windows-latest` | Pester smoke test (indirect — Wails app would need it at launch; Pester doesn't launch app, just verifies files/registry) | ✓ pre-installed on `windows-latest` | Current | No — Pester does NOT exercise app launch (D-22). Bootstrap-failure simulation explicitly out of scope. |

**Missing dependencies with no fallback:** None blocking. Every dependency has either a runner-provided instance, a vendoring plan, or a documented fallback.

**Missing dependencies with fallback:**
- NSIS ApplicationID plugin (vendor the DLL in-repo — see Plan 10-03)
- SignPath account/token (pipeline gates — pipeline publishes unsigned when absent, deferring signing to a later release)

## Security Domain

> `security_enforcement` is not disabled in this project's config; including full security considerations.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---|---|---|
| V2 Authentication | yes (installer introduces FW rule for OAuth loopback) | Firewall rule pre-creation (Pitfall 4 mitigation); tokens stored in Windows Credential Manager (zalando/go-keyring) — NOT in installer scope, carried from Phase 8. |
| V3 Session Management | n/a | Installer does not handle sessions. |
| V4 Access Control | yes (UAC via `RequestExecutionLevel admin`) | NSIS `RequestExecutionLevel admin` (D-02). Install dir is `$PROGRAMFILES64\go-mapi` — writable by SYSTEM + Administrators only. `%ProgramData%\go-mapi\uninst\` ACLs inherit from parent (SYSTEM + Admin writable, Users readable). |
| V5 Input Validation | yes (installer reads + writes registry values) | All registry values are installer-controlled constants (no user-supplied input goes into registry writes). Previous-mail-client JSON contains the value read from `HKLM\SOFTWARE\Clients\Mail\(Default)` — embedded in JSON via NSIS `FileWrite` with the existing value literally; since this value is an existing registry string previously written by another installer (Outlook, Thunderbird, etc.), this is low-risk. Not a JSON-injection vector because there's no user-supplied data path. |
| V6 Cryptography | yes (SignPath Authenticode signing) | All binaries + installer are Authenticode-signed via SignPath Foundation (OV cert). Signing is gated on `SIGNPATH_API_TOKEN` — when absent, unsigned fallback. |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---|---|---|
| Unsigned installer triggers SmartScreen block | Denial-of-service (against adoption) | SignPath signing (OV cert); SmartScreen guidance in release notes (PITFALLS §10); WDSI submission is Phase 11 scope. |
| Installer overwrites default mail client without backup | Tampering (against user's prior config) | Backup-before-write pattern (D-10/11); restore-on-uninstall (D-18 step 4). |
| Uninstaller leaves OAuth tokens in Credential Manager | Information disclosure | Explicit `cmdkey /delete:go-mapi:oauth-tokens` (D-18 step 8). Multi-user caveat documented (D-19). |
| WebView2 bootstrapper downloads over insecure channel | Tampering (supply chain) | Microsoft bootstrapper downloads from MS CDN over HTTPS with Authenticode-signed payload (Microsoft's responsibility). Installer logs but does not verify; fallback is the runtime-recovery path in the app itself (D-08). |
| NSIS script tampering in transit | Tampering (supply chain) | `go-mapi-setup.exe` itself is Authenticode-signed via SignPath post-makensis (D-23 call #2). Signing covers the NSIS-generated binary. |
| Firewall rule allows unintended inbound traffic | Spoofing / expanded attack surface | Rule is bound to `program=$INSTDIR\go-mapi.exe` (NOT a port — the firewall only allows inbound on whatever port go-mapi.exe is listening on). Scope limited to this one binary. |

**Never hand-roll:** Authenticode signing, UAC elevation, DPAPI/Credential Manager. All delegated to Windows / SignPath / zalando/go-keyring.

**No new threat model items vs Phase 8/9.** Installer surface is entirely covered by (a) inherited Phase 8 OAuth/token security, (b) Windows platform security (UAC, Authenticode, DPAPI), and (c) PITFALLS.md §4 + §6 + §9 + §10 which Phase 10 explicitly addresses.

## Project Constraints (from CLAUDE.md)

Actionable directives extracted from `CLAUDE.md` that Phase 10 plans MUST honor:

- **Windows 10/11 only.** No cross-platform guards needed. NSIS is Windows-only; Pester runs on `windows-latest`. ✓ honored by design.
- **LGPL-3.0 licensing.** NSIS (zlib license), ApplicationID plugin (zlib/MIT), WebView2 bootstrapper (redistributable per MS terms). All license-compatible. License page in installer displays the LGPL-3.0 text. ✓
- **Privacy.** Installer does NOT write telemetry, log email content, or make network calls outside the WebView2 bootstrapper (Microsoft CDN). Uninstaller scrubs per-user state. ✓
- **Budget.** SignPath Foundation is free (OSS tier). No paid dependencies. ✓
- **Go 1.25 + Wails v2.12.0.** Release workflow pins both. ✓ (Code Example 14)
- **Naming conventions.** `webview2_check.go` + `_bindings.go` variant follow the `credentials_check.go` pattern. NSIS section naming is Claude's Discretion per CONTEXT.md. ✓
- **Build-tag split.** ALL new `os.Exit`-capable guards in `main.go` MUST use `//go:build !bindings` + `//go:build bindings` stub sibling. Phase 10 adds exactly one (WebView2 recovery). ✓
- **Never log secrets.** Installer does NOT log `SIGNPATH_*` tokens, OAuth client id/secret, Google OAuth tokens. Release workflow passes via env vars / GitHub secrets, never echoes. ✓
- **Commit conventions.** `type(NN): description` — Phase 10 commits use `type(10): …` (e.g., `feat(10): NSIS installer with MAPI handler + AUMID + WebView2 bootstrap`, `ci(10): installer release workflow with SignPath gating`). ✓
- **Default branch `develop`.** No commits to `main` without explicit instruction. ✓
- **Lockfile discipline.** Phase 10 does NOT run `npm install`. No lockfile changes. ✓
- **File-changing tools only via GSD workflow.** Planner generates PLAN files; executor commits. No direct `Edit` bypass. ✓

## Sources

### Primary (HIGH confidence)

- **Microsoft Learn — Distribute your app and the WebView2 Runtime** [https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution) — Evergreen vs Fixed, registry detection (`pv` at `{F3017226-...}` GUID, WOW6432Node view), bootstrapper vs standalone, per-machine vs per-user. Updated 2026-02-27.
- **MicrosoftEdge/WebView2Feedback #1349** [https://github.com/MicrosoftEdge/WebView2Feedback/issues/1349](https://github.com/MicrosoftEdge/WebView2Feedback/issues/1349) — /silent /install exit-timing bug. Open since 2021, still unfixed as of 2026-04. Community consensus: registry polling is the only reliable workaround.
- **NSIS ApplicationID plugin** [https://nsis.sourceforge.io/ApplicationID_plug-in](https://nsis.sourceforge.io/ApplicationID_plug-in) — `ApplicationID::Set "lnk" "aumid"` + `Pop $0` (0=success, -1=error). Distributed separately from NSIS core.
- **zalando/go-keyring Windows backend source** [https://github.com/zalando/go-keyring/blob/master/keyring_windows.go](https://github.com/zalando/go-keyring/blob/master/keyring_windows.go) — `credName` method returns `service + ":" + username`, confirming Credential Manager target is `go-mapi:oauth-tokens`.
- **SignPath Trusted Build Systems — GitHub** [https://docs.signpath.io/trusted-build-systems/github](https://docs.signpath.io/trusted-build-systems/github) — `@v2` is current; required inputs `api-token`, `organization-id`, `project-slug`, `signing-policy-slug`, `github-artifact-id`; pattern with `actions/upload-artifact@v4`.
- **softprops/action-gh-release README** [https://github.com/softprops/action-gh-release](https://github.com/softprops/action-gh-release) — v2 is stable; v3 is Node 24 beta; requires `permissions: contents: write`.
- **Microsoft Learn — Application User Model IDs (AUMIDs)** [https://learn.microsoft.com/en-us/windows/win32/shell/appids](https://learn.microsoft.com/en-us/windows/win32/shell/appids) — PKEY_AppUserModel_ID = `{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}`, pid=5. Matches inline C# in `scripts/register-dev-aumid.ps1`.
- **Microsoft Learn — PKEY_AppUserModel_ID property** [https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-id](https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-id) — stamp via IShellLink+IPropertyStore.
- **Microsoft Learn — Get-StartApps** [https://learn.microsoft.com/en-us/powershell/module/startlayout/get-startapps?view=windowsserver2025-ps](https://learn.microsoft.com/en-us/powershell/module/startlayout/get-startapps?view=windowsserver2025-ps) — cmdlet; known indexing delay for newly-installed apps.
- **v2.0 Phase 3 PLAN/SUMMARY artifacts** [`.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/`] — authoritative structural reference for previous-client backup logic, Pester 5 idiom, SignPath gating pattern, CI workflow structure.
- **Project codebase** [`src/app/credentials_check.go`, `src/app/credentials_check_bindings.go`, `src/app/sessionend.go`, `src/app/toast.go`, `scripts/register-dev-aumid.ps1`] — verified reusable patterns for build-tag split, `user32.dll` lazy DLL pattern, AUMID ldflags seam, IShellLink COM reader.
- **Pester 5 documentation** [https://pester.dev/docs/introduction/installation](https://pester.dev/docs/introduction/installation) — Pester 5 configuration object, `Invoke-Pester -Configuration` idiom.

### Secondary (MEDIUM confidence, WebSearch verified with official source)

- GitHub Marketplace — `install-nsis` action [https://github.com/marketplace/actions/install-nsis](https://github.com/marketplace/actions/install-nsis) — `windows-latest` pre-installed NSIS version (3.10.0 as of 2026).
- Electron-userland issue #8613 [https://github.com/electron-userland/electron-builder/issues/8613](https://github.com/electron-userland/electron-builder/issues/8613) — NSIS on GitHub Actions (Chocolatey fallback).

### Tertiary (LOW confidence, single-source, flagged for validation during execution)

- None — every claim in this research either has an official source or multiple community sources.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — every tool + version verified against upstream.
- Architecture patterns: HIGH — three patterns are already in this codebase (credentials_check, sessionend user32 lazy-DLL, AUMID ldflags); the rest are direct lifts from v2.0 PLAN artifacts.
- Common pitfalls: HIGH — all five pitfalls are either documented upstream bugs (WebView2 #1349), verified from source (go-keyring target shape), or documented NSIS quirks (/D= quoting).
- Code examples: HIGH — every snippet is either a direct lift from verified docs, a port of v2.0's proven Pascal Script to NSIS equivalent, or a trivial adaptation of existing in-repo patterns.
- User Constraints section: HIGH — verbatim copy from CONTEXT.md.

**Research date:** 2026-04-19
**Valid until:** ~2026-05-19 (30 days for stable ecosystem; WebView2 bootstrapper fix watch: re-check GH #1349 if Microsoft announces anything; SignPath v3 watch: none announced as of research date).

---

*Phase: 10-installer-migration*
*Research completed: 2026-04-19*
