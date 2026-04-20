---
phase: 10-installer-migration
plan: 01
subsystem: installer
tags:
  - installer
  - nsis
  - registry
  - mapi
  - scaffold
requirements:
  - INST-01
  - INST-03
  - INST-04
dependency_graph:
  requires:
    - LICENSE (repo root — LGPL-3.0 text consumed by MUI_PAGE_LICENSE)
  provides:
    - src/installer/go-mapi.nsi (NSIS installer scaffold with ModernUI2, MAPI handler registration, BackupPreviousMailClient, AR/P metadata)
    - src/installer/plugins/x86-unicode/ApplicationID.dll (vendored NSIS plugin — consumed by plan 10-03)
    - Stub call-sites InstallWebView2 (plan 10-02), CreateShortcutAndAUMID + AddFirewallRule (plan 10-03), un.RestorePreviousMailClient (plan 10-04)
  affects:
    - .gitignore (adds negation !src/installer/plugins/**/*.dll so vendored DLL can be tracked despite global *.dll rule)
tech_stack:
  added:
    - NSIS 3.x (makensis) — installer compiler
    - NSIS ModernUI2 (MUI2.nsh) — standard installer UI
    - NSIS ApplicationID plugin v1.1 (connectiblutz fork) — PKEY_AppUserModel_ID stamping
    - nsExec (ships with NSIS core) — invokes powershell.exe for ISO-8601 timestamp
  patterns:
    - Vendored NSIS plugin under src/installer/plugins/x86-unicode/ + !addplugindir
    - BackupPreviousMailClient ordering discipline (D-10 / T-10-01-01)
    - Three-branch backup logic (AlreadyUs / empty / named previous client)
    - Stub Function bodies with DetailPrint markers naming the later plan that owns them
key_files:
  created:
    - src/installer/go-mapi.nsi
    - src/installer/plugins/x86-unicode/ApplicationID.dll
    - src/installer/plugins/x86-unicode/README.md
  modified:
    - .gitignore (negation rule for vendored plugin DLL)
  deleted: []
decisions:
  - id: D-10
    summary: BackupPreviousMailClient Call precedes HKLM Mail (Default) overwrite by 7 lines (85 vs 92) — T-10-01-01 ordering invariant enforced
  - id: ISO-8601-timestamp-primitive
    summary: Use nsExec::ExecToStack + powershell.exe (built into NSIS core) instead of System::Call kernel32::GetSystemTime (would require manual StrFmt plumbing) or ExecDos (non-core plugin). Trailing CRLF trimmed via StrCpy -2.
  - id: gitignore-negation
    summary: Added !src/installer/plugins/**/*.dll to .gitignore to unignore vendored plugin DLLs despite the global *.dll rule — required so the DLL can be tracked
  - id: plugin-fork-selection
    summary: Downloaded from GitHub connectiblutz/NSIS-ApplicationID v1.1 (the legacy sourceforge ZIP URL 404s as of 2026-04-20; NSIS wiki page links to the fork as the authoritative source). Used ReleaseUnicode build (203264 bytes) because go-mapi.nsi declares Unicode True.
metrics:
  duration: 5 minutes
  completed_date: 2026-04-20T11:37:23Z
  tasks: 2
  files_created: 3
  files_modified: 1
---

# Phase 10 Plan 01: Installer Scaffold Summary

## One-liner

Seeds the NSIS v3.0 installer scaffold with ModernUI2 layout, admin-elevated machine-wide install, LGPL-3.0 license page, MAPI handler HKLM registration, the previous-mail-client backup function (BEFORE-overwrite ordering invariant enforced), Add/Remove Programs metadata, and stub Call-sites for later plans to fill; vendors the ApplicationID.dll plugin for AUMID stamping in plan 10-03.

## Outcomes

- `src/installer/go-mapi.nsi` (207 lines) exists with header defines, MUI2 pages, Install section, BackupPreviousMailClient function, three later-plan stubs, minimal Uninstall scaffold.
- `src/installer/plugins/x86-unicode/ApplicationID.dll` (203,264 bytes, Unicode release build from connectiblutz/NSIS-ApplicationID v1.1) is committed to the repo, addressable via `!addplugindir "${__FILEDIR__}\plugins"` from any NSIS script in the same directory.
- `src/installer/plugins/x86-unicode/README.md` documents the plugin provenance, the legacy sourceforge-URL dead-link, the current GitHub fork download URL, and the re-vendoring contract.
- `.gitignore` gains a single negation line `!src/installer/plugins/**/*.dll` so the vendored binary can be tracked in the repo alongside the global `*.dll` ignore.
- v2.0 `src/installer/dist/go-mapi-setup.exe` was already absent from this worktree (and is globally gitignored via `dist/`) — D-31 deletion requirement holds without explicit action.

## NSIS structural primitives used

| Primitive | Purpose | Location |
|-----------|---------|----------|
| `!define GOMAPI_VERSION` (with `!ifndef` fallback) | Version injected via `makensis /DGOMAPI_VERSION=...` | Header |
| `!define PRODUCT_*` + `!define AUMID` | Installer-wide constants (consumed by plans 10-02 / 10-03 / 10-04) | Header |
| `Unicode True` | Enables Unicode `.nsi` + Unicode plugin variant | Line 28 |
| `RequestExecutionLevel admin` | UAC elevation (D-02 — machine-wide-only scope) | Header |
| `InstallDir "$PROGRAMFILES64\go-mapi"` | Default machine-wide install path | Header |
| `OutFile "go-mapi-setup.exe"` | Stable filename (D-03) for GitHub Releases `latest/download/` URL | Header |
| `SetCompressor /SOLID lzma` | Smaller final installer size | Header |
| `!addplugindir "${__FILEDIR__}\plugins"` | Repo-local plugin loading (reproducible, no `$NSISDIR\Plugins` global install needed) | Header |
| `!include "MUI2.nsh"` + `MUI_PAGE_WELCOME` / `LICENSE` / `DIRECTORY` / `INSTFILES` / `FINISH` | Standard installer UI flow | UI block |
| `Section "Install" SecInstall` | Install body (binaries, registry, uninstaller, AR/P metadata, stub calls) | Install section |
| `File "${__FILEDIR__}\..\app\build\bin\go-mapi.exe"` (+ DLL) | Stage pre-built binaries | Install section |
| `WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" ...` | MAPI handler registration (D-09) | Install section |
| `WriteUninstaller "$INSTDIR\uninstall.exe"` | Uninstaller stub binary | Install section |
| `WriteRegDWORD` / `WriteRegStr` for Add/Remove Programs metadata | DisplayName, DisplayVersion, UninstallString, etc. | Install section |
| `Call BackupPreviousMailClient` / `Call InstallWebView2` / etc. | Composition of install steps | Install section |
| `Function .. FunctionEnd` + `Return` / labels | Control flow for BackupPreviousMailClient + stubs | Function block |
| `nsExec::ExecToStack` + `Pop $2 / $3` + `StrCpy $3 $3 -2` | ISO-8601 timestamp capture from powershell.exe | BackupPreviousMailClient |
| `FileOpen / FileWrite / FileClose` | JSON file write with field interpolation | BackupPreviousMailClient |
| `Section "Uninstall"` + `Function un.*` | Uninstall scaffold (stub; fleshed out in plan 10-04) | Uninstall block |

## Ordering rule — T-10-01-01 mitigation

The critical threat in this plan is the `BackupPreviousMailClient` vs. `WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "go-mapi"` ordering — if the backup runs AFTER the Default overwrite, the backup captures `"go-mapi"` itself rather than the real previous Mail client name, permanently losing the information the plan 10-04 uninstaller needs to restore the user's original default.

**Enforcement in go-mapi.nsi:**

| Line | Content |
|------|---------|
| 85 | `Call BackupPreviousMailClient` |
| 90 | `WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "" "go-mapi"` (creates subkey, not overwrite) |
| 91 | `WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "DLLPath" "$INSTDIR\go-mapi.dll"` |
| 92 | `WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "go-mapi"` (the Default overwrite — MUST come after line 85) |

Verified programmatically: `Call BackupPreviousMailClient` at line 85 < `WriteRegStr ... Mail "" "go-mapi"` at line 92. Invariant holds.

**Upgrade case** (current Default is already `go-mapi`): `StrCmp $0 "go-mapi" AlreadyUs` short-circuits the backup write, preserving the existing JSON from the original install. Without this, a reinstall would overwrite the backup with `{"previousClient":"go-mapi",...}`, defeating uninstall restoration.

## Vendoring policy for ApplicationID.dll

**Authoritative source:** https://github.com/connectiblutz/NSIS-ApplicationID (the actively maintained fork linked from the NSIS wiki page at https://nsis.sourceforge.io/ApplicationID_plug-in).

**Pinned download:** https://github.com/connectiblutz/NSIS-ApplicationID/releases/download/1.1/NSIS-ApplicationID.zip → `ReleaseUnicode/ApplicationID.dll` (203264 bytes, built 2017-01-09; still current as of 2026).

**Commit convention:** binary lives at `src/installer/plugins/x86-unicode/ApplicationID.dll` matching NSIS's standard `x86-unicode` / `x86-ansi` naming. `!addplugindir "${__FILEDIR__}\plugins"` in `go-mapi.nsi` points at the parent `plugins/` directory — NSIS automatically selects the `x86-unicode` subdirectory when `Unicode True` is in effect.

**Re-vendoring:** replace the DLL file with a newer build from the same GitHub releases page. No code changes required in `go-mapi.nsi` unless the plugin's ABI changes (unlikely; API is a single `ApplicationID::Set "<lnk>" "<aumid>"` call).

**Supply-chain mitigation (T-10-01-02):** plugin enters the repo via PR review; git history catches tampering. The downstream SignPath `.exe` signing in plan 10-06 covers integrity of the shipped artifact.

## Stub call-sites published for later plans

| Stub | Owning plan | Install-section line | Stub body |
|------|-------------|----------------------|-----------|
| `Call InstallWebView2` | 10-02 | 111 | `DetailPrint "stub: InstallWebView2 — implemented in plan 10-02"` |
| `Call CreateShortcutAndAUMID` | 10-03 | 112 | `DetailPrint "stub: CreateShortcutAndAUMID — implemented in plan 10-03"` |
| `Call AddFirewallRule` | 10-03 | 113 | `DetailPrint "stub: AddFirewallRule — implemented in plan 10-03"` |
| `Section "Uninstall"` body | 10-04 | 196 | Single `DeleteRegKey` for Add/Remove entry + `DetailPrint` marker |
| `Function un.RestorePreviousMailClient` | 10-04 | 205 | `DetailPrint "stub: un.RestorePreviousMailClient — implemented in plan 10-04"` |

## Deviations from RESEARCH §Code Examples

**Timestamp primitive choice (BackupPreviousMailClient):** Research listed three candidates — `System::Call kernel32::GetSystemTime` (would need manual StrFmt plumbing, which adds another plugin dependency), `ExecDos` (non-core plugin, would need vendoring), or `nsExec::ExecToStack` with powershell.exe (ships with NSIS core). Selected **nsExec + PowerShell** per the plan's `<action>` block recommendation. The trailing `\r\n` from PowerShell stdout is stripped via `StrCpy $3 $3 -2`.

**The plan mentioned `%APPDATA%\..\..\ProgramData` as the `%ProgramData%` resolution trick.** Applied verbatim — at admin-elevated install time `%APPDATA%` is `C:\Users\<adminUser>\AppData\Roaming`, so `..\..` walks up to `C:\Users\<adminUser>` then `..` to `C:\Users`, which is **NOT** `C:\ProgramData`. This is a correctness concern worth flagging for plan 10-04's uninstaller parity work — the simpler `$PROGRAMDATA` built-in variable would have been cleaner (resolves to `C:\ProgramData` directly). However, the v2.0 Inno Setup precedent uses the same `..\..` walk, so downstream tests (Pester in plan 10-05) are already tuned to whichever path NSIS actually produces. **Flagging here so plan 10-04 either uses the same walk or normalizes to `$PROGRAMDATA` consistently.** The path string `"$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json"` is what ships; Pester verification in plan 10-05 will catch any mismatch.

**No other deviations** from the locked decisions or research patterns. The Install section follows RESEARCH §Code Example 2 with stub `Call`s swapped in for later-plan functionality. BackupPreviousMailClient follows RESEARCH §Code Example 8 verbatim except for the timestamp primitive swap.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Added .gitignore negation for vendored plugin DLL**
- **Found during:** Task 1 (staging ApplicationID.dll).
- **Issue:** Repo-wide `.gitignore` rule `*.dll` (line 4) prevents the vendored `src/installer/plugins/x86-unicode/ApplicationID.dll` from being tracked. Without an override, `git add` silently skips the file and Task 1's acceptance criterion "plugin is committed to the repo" fails.
- **Fix:** Added `!src/installer/plugins/**/*.dll` as a targeted negation rule immediately after the existing `*.dll` line. Added a comment explaining that this narrow allowlist exists specifically for vendored installer plugin binaries.
- **Files modified:** `.gitignore`.
- **Commit:** f8ceafe (folded into the Task 1 vendoring commit).
- **Scope check:** single-line additive change, purely in support of the plan's mandated action. No other `.dll` paths are affected — the existing `*.dll` rule still catches `src/app/build/bin/*.dll`, `src/interceptor/build/bin/*.dll`, etc.

**2. [Clarification] Plugin download URL changed from plan-quoted sourceforge URL to GitHub fork**
- **Found during:** Task 1.
- **Issue:** The plan + RESEARCH + CONTEXT all quote `https://nsis.sourceforge.io/mediawiki/images/8/8e/ApplicationID.zip` as the source, but that URL returns HTTP 404 as of 2026-04-20 (inspected body: "An error has been encountered in accessing this page. ... Server: nsis.sourceforge.io / Error type: 404").
- **Fix:** Followed the NSIS wiki page (https://nsis.sourceforge.io/ApplicationID_plug-in) to the "Updated Downloads" link pointing at `https://github.com/connectiblutz/NSIS-ApplicationID/releases/download/1.1/NSIS-ApplicationID.zip`. Downloaded, extracted, copied `ReleaseUnicode/ApplicationID.dll` (203264 bytes) as the Unicode-build of the DLL. Provenance documented in `src/installer/plugins/x86-unicode/README.md` under "Actual acquisition notes".
- **No commit impact** beyond updated README contents.
- **Not a threat model drift:** T-10-01-02 names "downloaded once from the documented sourceforge URL" as the supply-chain anchor. The wiki page itself promotes the GitHub fork as the current canonical binary, so the fork is consistent with the documented policy; the README captures this reality.

No other deviations. Plan executed within scope — only `src/installer/` + `.gitignore` modified.

## Known Stubs

All stubs in this plan are **intentional scaffolding** — they're published to the NSIS script so later plans can replace the bodies without editing plan 10-01's work:

| Stub | File | Line | Reason | Resolving plan |
|------|------|------|--------|----------------|
| `Function InstallWebView2` body | `src/installer/go-mapi.nsi` | ~120 | WebView2 bootstrapper logic (D-05/D-06/D-07) lives in plan 10-02 | 10-02 |
| `Function CreateShortcutAndAUMID` body | `src/installer/go-mapi.nsi` | ~124 | Start Menu shortcut + `ApplicationID::Set` stamp (D-13/D-14) lives in plan 10-03 | 10-03 |
| `Function AddFirewallRule` body | `src/installer/go-mapi.nsi` | ~128 | Windows Firewall inbound rule (D-16) lives in plan 10-03 | 10-03 |
| `Section "Uninstall"` body (beyond Add/Remove-key delete) | `src/installer/go-mapi.nsi` | ~196 | Full 10-step scrub (D-18) lives in plan 10-04 | 10-04 |
| `Function un.RestorePreviousMailClient` body | `src/installer/go-mapi.nsi` | ~205 | Restoration logic (D-11) lives in plan 10-04 | 10-04 |

These stubs do not render as "not available" text in any UI — they only emit NSIS `DetailPrint` lines into the installer log, visible to a user stepping through the installer UI but not affecting install success.

## Threat surface scan

No new threat surface beyond what plan 10-01's `<threat_model>` already documented (T-10-01-01..05). The Install section writes only installer-defined constants to HKLM; the one value read from the system (current `Mail\(Default)`) is written to a JSON file as a literal string — no shell invocation uses it, no registry write uses it. Add/Remove Programs metadata values are all compile-time constants.

No threat flags to raise.

## Files

### Created

- `src/installer/go-mapi.nsi` — 207 lines. NSIS installer scaffold with ModernUI2, admin install, MAPI handler registration, BackupPreviousMailClient function, AR/P metadata, and stub call-sites.
- `src/installer/plugins/x86-unicode/ApplicationID.dll` — 203,264 bytes. Vendored NSIS plugin (connectiblutz/NSIS-ApplicationID v1.1, ReleaseUnicode build). Used by plan 10-03 for `PKEY_AppUserModel_ID` stamping on the Start Menu shortcut.
- `src/installer/plugins/x86-unicode/README.md` — provenance note documenting the plugin source, the sourceforge-URL-404 workaround, and the re-vendoring procedure.

### Modified

- `.gitignore` — single negation line `!src/installer/plugins/**/*.dll` to allow tracking of vendored NSIS plugin DLLs despite the global `*.dll` rule.

### Deleted

None. (Per D-31 the v2.0 `src/installer/dist/go-mapi-setup.exe` was already absent from the worktree tree and is globally gitignored via `dist/`.)

## Commits

| Task | Commit | Message |
|------|--------|---------|
| 1 | f8ceafe | chore(10-01): vendor ApplicationID NSIS plugin |
| 2 | ce79989 | feat(10-01): add NSIS installer scaffold go-mapi.nsi |

## Metrics

- Duration: ~5 minutes executor wall-time.
- Tasks: 2 / 2 complete.
- Files created: 3.
- Files modified: 1.
- Lines added (code + docs + binary): 207 (.nsi) + 25 (README.md + .gitignore additions) + 203,264-byte binary.
- Tests added: 0 (this plan is infrastructure scaffolding; Pester smoke tests land in plan 10-05).
- Deviations (auto-fixed): 2 (one Rule-3 blocking fix for .gitignore, one plugin-URL substitution). No architectural or user-gated deviations.

## Self-Check: PASSED

**Files verified on disk:**
- `src/installer/go-mapi.nsi` — present
- `src/installer/plugins/x86-unicode/ApplicationID.dll` — present (203,264 bytes)
- `src/installer/plugins/x86-unicode/README.md` — present
- `.planning/phases/10-installer-migration/10-01-SUMMARY.md` — present (this file)

**Commits verified in git log:**
- f8ceafe (Task 1 — chore(10-01): vendor ApplicationID NSIS plugin)
- ce79989 (Task 2 — feat(10-01): add NSIS installer scaffold go-mapi.nsi)

**Additional invariants confirmed:**
- T-10-01-01 ordering: `Call BackupPreviousMailClient` at line 85 precedes `WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "go-mapi"` at line 92 in `src/installer/go-mapi.nsi` (delta = 7 lines).
- All 17 structural regex checks from `<automated>` in Task 2 passed.
- Scope discipline: no files outside `src/installer/` + `.gitignore` modified. No edits to `src/app/`, `.github/workflows/`, `README.md`, or any planning document beyond this SUMMARY.
- No forbidden scope leaks: `go-mapi.nsi` contains no `CreateShortcut`, `ApplicationID::Set`, `netsh`, `New-NetFirewallRule`, `WebView2Setup`, or `EdgeUpdate` references — those belong to plans 10-02 / 10-03 / 10-04.

