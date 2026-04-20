---
phase: 10-installer-migration
verified: 2026-04-20T14:20:00Z
status: human_needed
score: 5/5 roadmap success criteria structurally satisfied (2 environment-gated, pending live-CI + manual install verification)
overrides_applied: 0
human_verification:
  - test: "Trigger the installer-smoke.yml workflow on a PR or via workflow_dispatch and observe it exits green"
    expected: "Pester 5 suite runs on windows-latest, all 13 D-21 items pass (silent install exits 0, binaries deposited, MAPI key + DLLPath registered, backup JSON at %ProgramData%\\go-mapi\\uninst\\previous-mail-client.json parses, Start Menu .lnk has AUMID com.marcfargas.gomapi, firewall rule present; after uninstall: install dir empty, MAPI key gone, firewall rule gone, %APPDATA%\\go-mapi gone, cmdkey target scrubbed, .lnk gone). Workflow publishes the go-mapi-setup.exe artifact for manual inspection."
    why_human: "This verification environment cannot invoke makensis, cannot register a HKLM MAPI handler, and cannot run elevated install/uninstall. Only a Windows runner (or a disposable VM) can exercise the full round-trip. Item 4 in particular (BackupPreviousMailClient path resolution $APPDATA\\..\\..\\ProgramData\\go-mapi\\uninst) depends on NSIS runtime path expansion that can't be validated without running the installer — the 10-01 SUMMARY itself flagged this path as a correctness concern to be caught by this CI run."
  - test: "Exercise the installer-release.yml workflow via workflow_dispatch with dry_run=true on develop, then on a scratch tag (e.g. v0.0.1-rc1) to confirm the signed-release path end-to-end"
    expected: "Dry-run: pipeline builds + (if SIGNPATH_API_TOKEN is set) signs binaries + installer via SignPath v2 two-pass flow, uploads go-mapi-setup.exe as a workflow artifact, does NOT publish a GitHub release. Scratch tag: same pipeline publishes the installer to the GitHub Release page, signed if token is set, unsigned (with SmartScreen warning) otherwise."
    why_human: "Requires GitHub-hosted Windows runner plus SignPath organization configuration (SIGNPATH_ORG_ID, SIGNPATH_PROJECT_SLUG, SIGNPATH_SIGNING_POLICY_SLUG secrets). SignPath consent flow and actual Authenticode validation of the emitted .exe can only be confirmed by running the workflow and inspecting the resulting binary."
  - test: "Manually install go-mapi-setup.exe on a clean Windows 10/11 machine where WebView2 Runtime is NOT installed, confirm the bootstrapper fires and the runtime is installed within ~60s"
    expected: "Installer UI appears, progresses through LGPL license page, installs to C:\\Program Files\\go-mapi, WebView2 bootstrapper invokes silently, registry key appears within 60s, go-mapi launches without the 'WebView2 required' MessageBox. If WebView2 is not installed within 60s, installer continues (per D-07) and app falls back to the runtime-missing MessageBox (per D-08)."
    why_human: "Requires a test VM with WebView2 uninstalled (non-trivial — most modern Win11 images ship with it). CI runners have WebView2 preinstalled, so the bootstrapper path is not exercised there. WR-01 (inverted StrCmp in DetectWebView2) means the installer's bootstrap path is suspected to never fire even when runtime is absent — human verification on a WebView2-less machine is the only way to confirm the Go-side fallback (checkWebView2 in webview2_check.go) actually catches this at app launch."
  - test: "Install v3.0 on a machine where HKLM\\SOFTWARE\\Clients\\Mail\\(Default) already points at a real mail client (e.g. Microsoft Outlook or Thunderbird), then uninstall and confirm (Default) is restored"
    expected: "After install: previous-mail-client.json contains {\"previousClient\":\"Outlook\",...} (or equivalent). After uninstall: HKLM\\SOFTWARE\\Clients\\Mail\\(Default) reads back to the original value. If previousClient was null (fresh Windows with no Mail default), uninstall clears (Default) to empty string."
    why_human: "The Pester smoke test runs on a runner with no preinstalled mail client, so un.RestorePreviousMailClient's happy-path (restore to a named previous client) is never exercised. Only the fallback chain (Microsoft Outlook -> Outlook -> Windows Mail -> clear) can be tested there. Real user systems vary; this needs a real-world install site with a prior default."
  - test: "Install v3.0 on a machine with a prior v2.x go-mapi installation still present (Chrome/Edge extension + native-host); confirm the README 'uninstall v2 first' directive is visible and v3 installs cleanly afterwards"
    expected: "User follows README directive, uninstalls v2 via Settings -> Apps -> Installed apps, then runs go-mapi-setup.exe. v3 installs without conflicts. D-20 clean-break: the v3 installer does NOT touch v2 artifacts (native-messaging manifests at %APPDATA%\\Google\\Chrome\\NativeMessagingHosts\\ etc.)."
    why_human: "ROADMAP SC #2 originally specified 'installer removes native messaging manifests'; CONTEXT D-20 explicitly supersedes this with a clean-break strategy documented in README. Manual verification confirms the directive is adequate for real users migrating from v2."
---

# Phase 10: Installer + Migration Verification Report

**Phase Goal:** A signed single-file installer sets up the Wails app for a new user (including WebView2 runtime and AppUserModelID), removes v2.x artifacts (clean-break per D-20 — documented, not automated), and provides a clean uninstall path.
**Verified:** 2026-04-20T14:20:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | A user with no prior go-mapi runs `go-mapi-setup.exe` and the app appears in the system tray within two minutes, including WebView2 bootstrap if absent | ? UNCERTAIN | NSIS script has DetectWebView2 + InstallWebView2 + 60s poll + continue-on-timeout + Go-side checkWebView2 fallback. WR-01 (inverted StrCmp in DetectWebView2 lines 195-204) makes installer treat pv=0.0.0.0 as "runtime present" and skip bootstrap; Go-side checkWebView2.go:45 correctly rejects 0.0.0.0, so overall runtime-recovery still works, but the two layers are out of sync. Needs live-install verification on a WebView2-less machine. |
| 2 | On a v2.x machine, installer removes native messaging manifests and old MAPI entries, leaving no v2 residue | ✓ VERIFIED (per override via D-20) | CONTEXT D-20 supersedes original SC #2 with clean-break strategy: v2 uninstall is user-driven (README directive), v3 installer intentionally has NO v2 scrub logic. Verified: no `NativeMessagingHosts` or `nativeMessaging` matches in src/installer/go-mapi.nsi (grep count = 0). README.md carries the "uninstall v2.x first" blockquote at line 57. |
| 3 | Toasts persist in Windows Action Center (AUMID + Start Menu shortcut registered by installer) | ✓ VERIFIED | src/installer/go-mapi.nsi:300-305 CreateShortcut $SMPROGRAMS\go-mapi.lnk -> $INSTDIR\go-mapi.exe with description "go-mapi — MAPI-to-Gmail bridge". Line 311 ApplicationID::Set "$SMPROGRAMS\go-mapi.lnk" "${AUMID}" where ${AUMID}=com.marcfargas.gomapi (line 36). rc check via Pop $0 + StrCmp $0 "0" AumidOk + WARNING DetailPrint branch (lines 312-318). Vendored plugin present at src/installer/plugins/x86-unicode/ApplicationID.dll (203,264 bytes). AUMID literal matches installer-release.yml ldflags `-X main.aumidOverride=com.marcfargas.gomapi`. Pester item 5 asserts readback via IPropertyStore (AumidReader.ps1). |
| 4 | Uninstaller removes Wails binary, MAPI handler, registry keys, AUMID shortcut, and temp dir; nothing remains | ✓ VERIFIED (structural) | Section "Uninstall" (lines 360-414) executes D-18 10-step scrub in order: firewall delete (1), shortcut Delete (2), DeleteRegKey MAPI handler (3), un.RestorePreviousMailClient (4), RMDir /r ProgramData uninst (5), RMDir /r TEMP (6), RMDir /r APPDATA (7), cmdkey /delete:go-mapi:oauth-tokens (8, COLON verified), Delete binaries (9), RMDir INSTDIR (10), DeleteRegKey Add/Remove Programs. un.RestorePreviousMailClient implements D-11 target-key existence verify + 3-fallback chain (Microsoft Outlook -> Outlook -> Windows Mail -> clear). Actual round-trip deferred to CI (Pester) + manual on-device verification. |
| 5 | Pester 5 smoke test verifies install and uninstall round-trip on windows-latest CI | ✓ VERIFIED (structural) | src/installer/tests/installer.Tests.ps1 (153 lines) contains 13 numbered It blocks covering D-21 items 1-13, split across Context "Silent install" + Context "Silent uninstall". Uses Pester 5 idioms (Should -BeTrue/-BeFalse, New-PesterConfiguration in workflow, NOT -EnableExit). AumidReader.ps1 provides inline-C# IPropertyStore reader (stable primitive, NOT Get-StartApps). .github/workflows/installer-smoke.yml triggers on push main/develop + pull_request + workflow_dispatch with paths filter; invokes makensis, runs Invoke-Pester with Detailed verbosity. Live execution deferred to human verification (requires GH Actions environment). |

**Score:** 5/5 roadmap success criteria structurally satisfied; 4 of 5 require live-environment verification to fully close.

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/installer/go-mapi.nsi` | NSIS installer script (full scaffold + WebView2 + AUMID + firewall + 10-step uninstall + restore helpers) | ✓ VERIFIED | 567 lines; all required sections present (Header with AUMID define, MUI2 pages with LGPL license, Install section with MAPI writes + stub-calls-filled, DetectWebView2 + InstallWebView2, CreateShortcutAndAUMID, AddFirewallRule, Section Uninstall with 10-step scrub, un.RestorePreviousMailClient + un.StrContains + un.StrExtract helpers) |
| `src/installer/plugins/x86-unicode/ApplicationID.dll` | Vendored NSIS plugin (~200 KB) | ✓ VERIFIED | 203,264 bytes present; provenance in plugins/x86-unicode/README.md |
| `src/installer/MicrosoftEdgeWebview2Setup.exe` | Vendored Microsoft Evergreen bootstrapper (~1.7 MB) | ✓ VERIFIED | 1,699,256 bytes; PE binary; sourced from https://go.microsoft.com/fwlink/p/?LinkId=2124703 per 10-02 summary |
| `src/app/webview2_check.go` (!bindings) | checkWebView2() + showWebView2MissingDialog() | ✓ VERIFIED | 68 lines; three-path registry probe (WOW6432Node HKLM, HKLM, HKCU) against GUID {F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}; rejects pv=="" and pv=="0.0.0.0" correctly (line 45); uses procMessageBoxW via existing user32 LazyDLL (no redeclaration) |
| `src/app/webview2_check_bindings.go` (bindings) | No-op stubs | ✓ VERIFIED | 14 lines; both functions return nil/no-op matching signatures |
| `src/app/webview2_check_test.go` | Windows registry seed tests | ✓ VERIFIED | Created per 10-02 summary; tests run on dev box, SKIP gracefully on machines with preinstalled WebView2 (`windows-latest` CI) |
| `src/app/sessionend.go` (extended) | procMessageBoxW appended to user32 var block | ✓ VERIFIED | Grep: 2 matches in sessionend.go at lines 34, 39 (comment + NewProc); user32 LazyDLL declared ONCE (no redeclaration) |
| `src/app/main.go` (extended) | checkWebView2() before checkOAuthCredentials() | ✓ VERIFIED | Line 38 (checkWebView2) < line 51 (checkOAuthCredentials). Error path shows dialog + browser.OpenURL + os.Exit(1). |
| `src/app/wails.json` | info.productVersion field | ✓ VERIFIED | JSON parses; info.productVersion = "0.0.0" placeholder per D-26 (release workflow validates against tag) |
| `src/installer/tests/installer.Tests.ps1` | Pester 5 13-item D-21 suite | ✓ VERIFIED | 153 lines; 13 It blocks (1-13); cross-plan literals hardcoded (com.marcfargas.gomapi, go-mapi OAuth loopback, go-mapi:oauth-tokens) |
| `src/installer/tests/AumidReader.ps1` | Inline-C# IPropertyStore reader | ✓ VERIFIED | 113 lines; defines Get-ShortcutAumid + GoMapi.AumidReader.PublicReader::GetAumid; uses PKEY_AppUserModel_ID {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3} PID 5; PROPVARIANTClear + ReleaseComObject lifecycle |
| `.github/workflows/installer-smoke.yml` | Per-PR Pester gate | ✓ VERIFIED | 120 lines; triggers on push main/develop + pull_request + workflow_dispatch with paths filter; windows-latest; builds DLL + Wails (dev ldflags, no SignPath) + installer; Invoke-Pester with Pester 5 config; uploads installer artifact |
| `.github/workflows/installer-release.yml` | Tag-triggered signed release pipeline | ✓ VERIFIED | 190 lines; triggers on `tags: ['v*']` + workflow_dispatch with dry_run; workflow-level permissions contents:write + actions:read; validates wails.json info.productVersion against tag; all four ldflags use `main.<var>` prefix; SignPath v2 (NOT v1) two-pass gated on SIGNPATH_API_TOKEN; softprops/action-gh-release@v2 with body_path release-template.md; publish gated on push event (workflow_dispatch always artifact-only) |
| `.github/release-template.md` | Static v3.0 release notes | ✓ VERIFIED | 31 lines; ## go-mapi v3.0 heading, Installation section, v2.x uninstall directive, WebView2 + Win10/11 system requirements, LGPL-3.0 reference, go-mapi-setup.exe mentioned, README link |
| `README.md` (extended) | v2 uninstall note + multi-user caveat | ✓ VERIFIED | Line 57 v2-uninstall-first blockquote; lines 61-68 multi-user RDS subsection with go-mapi:oauth-tokens (colon, no slash), APPDATA go-mapi, Credential Manager |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| go-mapi.nsi | plugins/x86-unicode/ApplicationID.dll | !addplugindir + ApplicationID::Set | ✓ WIRED | Line 51 `!addplugindir "${__FILEDIR__}\plugins"`; line 311 `ApplicationID::Set "$SMPROGRAMS\go-mapi.lnk" "${AUMID}"` |
| go-mapi.nsi (InstallWebView2) | MicrosoftEdgeWebview2Setup.exe | File + ExecWait | ✓ WIRED | Line 244 `File "${__FILEDIR__}\MicrosoftEdgeWebview2Setup.exe"`; line 247 `ExecWait '"$INSTDIR\MicrosoftEdgeWebview2Setup.exe" /silent /install' $1`; 30-iteration × 2s poll loop; Delete cleanup on both success + timeout |
| go-mapi.nsi (install section) | go-mapi.exe + go-mapi.dll | File directive | ✓ WIRED | Lines 80-81 File directives staging pre-built binaries |
| go-mapi.nsi (install section) | HKLM MAPI handler | WriteRegStr | ✓ WIRED | Lines 90-92 three registry writes in correct order (subkey Default, DLLPath, Mail Default — with Call BackupPreviousMailClient at line 85 preceding by 7 lines) |
| go-mapi.nsi (BackupPreviousMailClient) | previous-mail-client.json | FileOpen/FileWrite | ⚠️ PATH-UNCERTAIN | Lines 149, 161, 433: path is `$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json`. 10-01 SUMMARY itself flagged this as a correctness concern: at admin-elevated install `$APPDATA` is typically the admin user's AppData\Roaming, so `..\..\ProgramData` resolves to `C:\Users\<admin>\ProgramData` NOT `C:\ProgramData`. Pester item 4 reads from `$env:ProgramData\go-mapi\uninst\...` (C:\ProgramData). Mismatch would make Pester item 4 fail. NSIS semantics for `$APPDATA` under RequestExecutionLevel admin vary — CI run is the authoritative check. |
| go-mapi.nsi (un.RestorePreviousMailClient) | backup JSON + HKLM registry | FileOpen + ReadRegStr + WriteRegStr | ✓ WIRED | Lines 422-491: reads JSON, detects null via un.StrContains, extracts name via un.StrExtract, verifies target subkey exists (D-11 dangling-handler mitigation), falls through to Microsoft Outlook -> Outlook -> Windows Mail -> clear. Register-clobber bug (IN-02/IN-03) currently invisible because callers use $0-$5 only. |
| go-mapi.nsi uninstall | firewall rule | netsh advfirewall firewall delete | ✓ WIRED | Line 366 `netsh advfirewall firewall delete rule name="go-mapi OAuth loopback"`; exact byte-for-byte match with install add rule at line 346 (grep confirms count add=1, delete=1) |
| go-mapi.nsi uninstall | Windows Credential Manager | cmdkey /delete:go-mapi:oauth-tokens | ✓ WIRED | Line 398 COLON target, matches src/app/auth.go keyringService/keyringUser convention per PATTERNS Shared Pattern 3; slash form absent in .nsi (grep count = 0) |
| installer-release.yml | wails.json info.productVersion | ConvertFrom-Json | ✓ WIRED | Line 68-81: reads `$json.info.productVersion`, compares to `github.ref_name -replace '^v',''`, throws on mismatch, skips for workflow_dispatch |
| installer-release.yml | SignPath v2 | signpath/github-action-submit-signing-request@v2 | ✓ WIRED | Two @v2 action invocations (lines 118, 151); zero @v1 references; all gated on SIGNPATH_API_TOKEN presence |
| installer-release.yml | GitHub Release asset | softprops/action-gh-release@v2 | ✓ WIRED | Line 177 with body_path: .github/release-template.md; publish gated on push event |
| main.go | webview2_check.go | call + dialog + browser + exit | ✓ WIRED | Lines 38-43: checkWebView2 -> logError -> showWebView2MissingDialog -> browser.OpenURL(webview2 download) -> os.Exit(1) |
| webview2_check.go | sessionend.go user32 | procMessageBoxW direct reference | ✓ WIRED | webview2_check.go:62 procMessageBoxW.Call(...); sessionend.go:39 `procMessageBoxW = user32.NewProc("MessageBoxW")` in existing user32 var block |
| installer.Tests.ps1 | AumidReader.ps1 | dot-source in BeforeAll | ✓ WIRED | Line 27 `. "$PSScriptRoot\AumidReader.ps1"` |
| installer-smoke.yml | Invoke-Pester | New-PesterConfiguration | ✓ WIRED | Lines 106-111 configure Run.Path + Run.Exit + Output.Verbosity then Invoke-Pester -Configuration |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| BackupPreviousMailClient | $0 (previousClient name) | ReadRegStr HKLM "SOFTWARE\Clients\Mail" "" | Yes — real Windows registry read | ✓ FLOWING (assuming `$APPDATA\..\..\ProgramData` resolves correctly at admin-elevated install — uncertain, see WIRING table) |
| checkWebView2 | pv (runtime version) | registry.OpenKey + GetStringValue on 3 paths | Yes — real registry probe; rejects "" and "0.0.0.0" | ✓ FLOWING |
| un.RestorePreviousMailClient | $1 (restoration target), $3 (JSON) | FileRead backup JSON + ReadRegStr HKLM\Mail\$1 | Yes — JSON parsed via un.StrExtract; target verified via ReadRegStr before WriteRegStr | ✓ FLOWING (happy path depends on JSON file being written correctly by BackupPreviousMailClient — same uncertainty as above) |
| installer.Tests.ps1 item 5 | $actual AUMID | Get-ShortcutAumid via IPropertyStore COM | Yes — reads .lnk property store | ✓ FLOWING (requires Windows runtime; CI gates this) |
| installer-release.yml ldflags | Version, aumidOverride, oauthClientID, oauthClientSecret | wails.json version + hardcoded AUMID + env-injected secrets | Yes on tag push with secrets set | ✓ FLOWING (contingent on repo secrets) |

### Behavioral Spot-Checks

Skipped most: no runnable entry points in this environment (no makensis, no Windows admin, no PowerShell Pester runner). Ran only what this environment supports:

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Go production build compiles | `go build ./src/app/...` | exit 0 | ✓ PASS |
| Go bindings build compiles | `go build -tags=bindings ./src/app/...` | exit 0 | ✓ PASS |
| Go vet passes | `go vet ./src/app/...` | exit 0 | ✓ PASS |
| Firewall rule name byte-for-byte match | `grep -c 'add rule name="go-mapi OAuth loopback"' .nsi` / `grep -c 'delete rule name="..."' .nsi` | 1 / 1 | ✓ PASS |
| No cmdkey slash form in any file | `grep -c 'go-mapi/oauth-tokens' src/installer/go-mapi.nsi README.md` | 0 / 0 | ✓ PASS |
| No v2 artifact cleanup creep | `grep -ci NativeMessagingHosts\|nativeMessaging src/installer/go-mapi.nsi` | 0 | ✓ PASS |
| No SignPath v1 references | `grep -c '@v1' installer-release.yml` for signpath action | 0 | ✓ PASS |
| Release workflow uses main.<var> ldflags (not wrong path) | `grep github.com/marcfargas/go-mapi/src/app installer-release.yml` | 1 match (in comment explaining errata, not in actual ldflags) | ✓ PASS |
| makensis installer compile | n/a | no makensis available | ? SKIP (CI-gated) |
| Pester test parse-check | n/a | no PowerShell/Pester available | ? SKIP (CI-gated) |
| Live install/uninstall round-trip | n/a | requires Windows admin runner | ? SKIP (human verification) |

### Requirements Coverage

| Requirement | Source Plans | Description | Status | Evidence |
|-------------|--------------|-------------|--------|----------|
| INST-01 | 10-01, 10-03, 10-06 | Signed installer produces single .exe that registers MAPI handler, places DLL, installs Wails app, registers AppUserModelID shortcut | ✓ SATISFIED (structural; signing live-gated) | go-mapi.nsi Install section writes all required pieces; installer-release.yml has SignPath two-pass v2. Live signing contingent on SignPath secrets + tag push. |
| INST-02 | 10-02 | Installer detects and bootstraps WebView2 Evergreen; fails gracefully with link to Microsoft runtime page if unreachable | ⚠️ PARTIAL | NSIS DetectWebView2 + InstallWebView2 + 60s poll + continue-on-timeout present; Go-side checkWebView2 + MessageBox + browser.OpenURL fallback present. WR-01 bug means DetectWebView2 treats pv=0.0.0.0 as present and installer skips bootstrap in that edge case, but Go-side correctly rejects 0.0.0.0 so the fallback dialog still fires. Overall "fails gracefully with link" contract holds via Go-side path. Requires human verification on a WebView2-less machine. |
| INST-03 | 10-01, 10-06 | Installer detects v2.x artifacts (native manifests, MAPI entries) and removes them | ✓ SATISFIED (via D-20 clean-break override) | Context D-20 supersedes ROADMAP wording: v2 uninstall is user-driven (README blockquote at line 57); v3 installer intentionally carries no v2 scrub. Grep confirms zero NativeMessagingHosts references. This is the phase's explicit scope decision. |
| INST-04 | 10-01 | Installer does NOT require admin for per-user install; admin only for machine-wide | ⚠️ DEVIATION | 10-01 plan declares `RequestExecutionLevel admin` (D-02 machine-wide only). Phase explicitly rejects per-user install because MAPI DLL requires HKLM registration. This deviates from the original REQ text but is covered by CONTEXT D-02 decision. Treat as accepted deviation. |
| INST-05 | 10-04 | Uninstall removes Wails binary, MAPI handler, registry keys, AUMID shortcut, temp dir residue | ✓ SATISFIED (structural) | D-18 10-step scrub in go-mapi.nsi:360-414 covers firewall, shortcut, MAPI key, (Default) restore, ProgramData, TEMP, APPDATA, Credential Manager, binaries, install dir. Live round-trip Pester-gated. |
| INST-06 | 10-03, 10-04 | Windows Firewall rule for loopback OAuth port added during install | ✓ SATISFIED | Line 346 netsh add; line 366 netsh delete; rule name "go-mapi OAuth loopback" byte-for-byte match; program-scoped to $INSTDIR\go-mapi.exe (narrow, port-stable). |
| INST-07 | 10-05 | Pester 5 smoke test verifies install + uninstall round-trip on fresh windows-latest | ✓ SATISFIED (structural; live-CI-gated) | installer.Tests.ps1 has 13 It blocks; installer-smoke.yml triggers on PR + develop/main push with paths filter. First actual green CI run pending. |

No orphaned requirements.

### Anti-Patterns Found

Cross-referenced against 10-REVIEW.md findings (WR-01, WR-02, WR-03 warnings + IN-01..06 info-level items):

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| src/installer/go-mapi.nsi | 194-204 | WR-01: Inverted StrCmp jumps in DetectWebView2 treat pv=0.0.0.0 as present | ⚠️ Warning | Installer skips bootstrap when runtime is broken but registry key exists. Mitigated by Go-side checkWebView2 correctly rejecting 0.0.0.0 — overall goal (graceful fallback with MS download link) still holds. Phase-goal-relevant but not blocking; human verification on WebView2-less machine required. |
| src/installer/go-mapi.nsi | 150, 162 | WR-02: JSON previousClient field not escaped for embedded quotes/backslashes | ⚠️ Warning | Edge-case: a mail client with a name containing `"` or `\` produces invalid JSON, breaking Pester item 4 + uninstall restore. Low attack surface (registry-controlled display names); real-world Japanese/enterprise-branded clients could trigger it. |
| .github/workflows/installer-smoke.yml | 39-40, 78, 113-118 | WR-03: OAuth client_secret embedded in uploaded smoke artifact | ⚠️ Warning | Client_secret for a Desktop OAuth app using PKCE is documented as "not confidential" per Google, so this is not a CVE-class leak. Still expands exposure beyond release-only. Suggested fix in 10-REVIEW.md: drop env vars from smoke workflow entirely (Pester never launches app). Not a phase-goal blocker. |
| src/installer/go-mapi.nsi | 131-170 | Path: `$APPDATA\..\..\ProgramData` — 10-01 SUMMARY self-flagged as uncertain resolution under admin elevation | ⚠️ Warning | Pester item 4 expects %ProgramData%\go-mapi\uninst\previous-mail-client.json at C:\ProgramData, but NSIS path may resolve to C:\Users\<admin>\ProgramData depending on runtime. CI Pester run is the authoritative check. If it fails, BackupPreviousMailClient + un.RestorePreviousMailClient both break. |
| src/app/webview2_check.go | 57-58 | IN-01: syscall.StringToUTF16Ptr is deprecated | ℹ️ Info | Prefer UTF16PtrFromString. Compile-time-safe (constants, no NUL), so no runtime hazard today. Style drift vs rest of codebase. |
| src/installer/go-mapi.nsi | 494-567 | IN-02/IN-03: un.StrContains + un.StrExtract have register-restore bugs ($R1/$R2 swapped on return, stray push leaked) | ℹ️ Info | Currently invisible because callers use $0-$5 only. Latent — future edits using $R* registers would trigger. |
| src/installer/go-mapi.nsi | 193, 202 | IN-04: DetectWebView2 leaves SetRegView 32 active on exit | ℹ️ Info | Currently benign (install section completes its HKLM writes before Call InstallWebView2). Latent hazard if future WriteRegStr HKLM lands after Call InstallWebView2. |
| src/installer/go-mapi.nsi | 439-443 | IN-05: JSON null detection is naive substring check, could false-match a client name containing `"previousClient":null` | ℹ️ Info | Extreme edge case; no real mail client name would contain this. |
| src/installer/tests/AumidReader.ps1 | 15-100 | IN-06: Add-Type idempotency guard checks wrong type name | ℹ️ Info | Guard checks `GoMapi.AumidReader.Reader` but entry point is `GoMapi.AumidReader.PublicReader`. Benign on clean CI runner; could mask stale definition on dev iteration. |

### Human Verification Required

See YAML frontmatter `human_verification` for the full list. Summary:

1. **installer-smoke.yml green run on CI** — exercises 13 D-21 items end-to-end on windows-latest. Authoritative check for path-resolution uncertainty on `$APPDATA\..\..\ProgramData`, WR-01 DetectWebView2 behavior (runner has WebView2 preinstalled so installer skips bootstrap anyway), and cross-plan literal consistency.
2. **installer-release.yml workflow_dispatch dry-run + scratch tag** — exercises SignPath two-pass flow + signed/unsigned resolution + softprops release attach. Requires repo SignPath secrets to be configured.
3. **Manual install on WebView2-less Windows 10/11 machine** — confirms the end-to-end bootstrap path and the Go-side fallback MessageBox + download URL actually fire. The only path that catches WR-01's operational impact.
4. **Install on system with prior real default mail client** — confirms un.RestorePreviousMailClient happy-path restores the named previous client rather than always falling through to the Microsoft Outlook / Outlook / Windows Mail fallback chain.
5. **v2.x migration walkthrough** — confirms README directive is adequate for real-world migration.

### Gaps Summary

Structural coverage of all five ROADMAP Success Criteria is complete and INST-01..07 requirements are accounted for (INST-03 via explicit CONTEXT D-20 clean-break decision; INST-04 via explicit CONTEXT D-02 machine-wide scope decision). However, Phase 10 is inherently a release-infra phase whose correctness can only be proven by running the artifacts it produces: the installer must actually compile, install, stamp, register, bootstrap, uninstall, and restore on a real Windows system. None of that is possible in this verification environment.

The 10-REVIEW.md surfaced three warnings:
- **WR-01 (inverted StrCmp in DetectWebView2):** phase-goal-relevant but the Go-side checkWebView2 correctly rejects `pv=0.0.0.0`, so the graceful-fallback contract holds. Installer may skip bootstrap in the `pv=0.0.0.0` edge case but the app then shows the MessageBox + download URL. Treat as a behavioral regression to fix in a gap-closure pass OR accept via override (phase goal "WebView2 bootstrapping if absent" is satisfied by the layered fallback, not by DetectWebView2 alone).
- **WR-02 (JSON quoting):** edge case for non-ASCII/quoted mail-client names. Deferrable.
- **WR-03 (OAuth secret in smoke artifact):** scope-creep mitigation concern, not a functional blocker. Deferrable with a follow-up ticket.

These are noted, not blocking the phase goal. Final closure (status -> passed) requires the five human verification items above.

---

_Verified: 2026-04-20T14:20:00Z_
_Verifier: Claude (gsd-verifier)_
