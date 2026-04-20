---
status: partial
phase: 10-installer-migration
source: [10-VERIFICATION.md]
started: 2026-04-20T12:29:15Z
updated: 2026-04-20T12:29:15Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. installer-smoke.yml first green CI run
expected: CI passes all 13 D-21 Pester items on windows-latest (push to develop triggers workflow, or workflow_dispatch manually). Validates $APPDATA-relative ProgramData path resolution, cross-plan literal consistency (AUMID, firewall rule name, cmdkey target, rule removal), and install/uninstall round-trip.
result: [pending]

### 2. installer-release.yml dry-run + scratch tag
expected: workflow_dispatch with dry_run=true completes the SignPath v2 two-pass signing flow (Wails binary + MAPI DLL first pass → makensis compile → installer second pass), attaches signed installer to a pre-release via softprops/action-gh-release@v2. Requires repo secrets (SIGNPATH_API_TOKEN, SIGNPATH_ORG_ID, SIGNPATH_PROJECT_SLUG, SIGNPATH_SIGNING_POLICY_SLUG, GOMAPI_OAUTH_CLIENT_ID, GOMAPI_OAUTH_CLIENT_SECRET) configured. If SIGNPATH_API_TOKEN absent, workflow must fall back to unsigned per D-24.
result: [pending]

### 3. Manual install on WebView2-less Windows 10/11 machine
expected: Installer detects missing WebView2, invokes bundled MicrosoftEdgeWebview2Setup.exe /silent /install, polls HKLM for up to 60s, continues on timeout per D-07. If user later launches go-mapi.exe with WebView2 still missing, Go-side checkWebView2() shows native Win32 MessageBox with download URL and exits cleanly. Exercises WR-01 operational impact: if DetectWebView2 StrCmp logic still triggers false-"found" on pv=0.0.0.0 after real install, installer skips bootstrap but Go-side dialog recovers.
result: [pending]

### 4. Install on Windows system with real prior default mail client configured
expected: BackupPreviousMailClient writes %ProgramData%\go-mapi\uninst\previous-mail-client.json with the actual prior client name (not "null"). On uninstall, un.RestorePreviousMailClient reads the JSON, verifies the target HKLM\SOFTWARE\Clients\Mail\<name> key still exists, and restores HKLM\SOFTWARE\Clients\Mail\(Default) to that name. If the prior client was uninstalled while go-mapi was installed, un.RestorePreviousMailClient falls through the Microsoft Outlook → Outlook → Windows Mail chain.
result: [pending]

### 5. v2.x migration walkthrough on a real v2 installation
expected: Follow the README instructions as a user with v2.x already installed. Uninstalling v2 first (per D-20 clean-break) then installing v3.0 produces a working system with no native-messaging-host leftovers, no extension leftovers, and a clean MAPI handler. README directive is adequate without requiring support questions.
result: [pending]

## Summary

total: 5
passed: 0
issues: 0
pending: 5
skipped: 0
blocked: 0

## Gaps
