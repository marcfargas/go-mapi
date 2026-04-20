---
phase: 10-installer-migration
plan: 03
subsystem: installer
tags:
  - installer
  - nsis
  - aumid
  - firewall
  - start-menu
  - toast
requirements:
  - INST-01
  - INST-06
dependency_graph:
  requires:
    - src/installer/go-mapi.nsi (plan 10-01 scaffold — stub Functions CreateShortcutAndAUMID + AddFirewallRule; ${AUMID} define; !addplugindir)
    - src/installer/plugins/x86-unicode/ApplicationID.dll (plan 10-01 vendored plugin — v1.1 Unicode build)
  provides:
    - "src/installer/go-mapi.nsi: Function CreateShortcutAndAUMID (real body) — CreateShortcut + ApplicationID::Set with Pop+StrCmp rc check"
    - "src/installer/go-mapi.nsi: Function AddFirewallRule (real body) — netsh advfirewall firewall add rule, program-scoped to $INSTDIR\\go-mapi.exe"
    - "byte-literal rule name 'go-mapi OAuth loopback' for plan 10-04 uninstall delete-rule to match"
    - "byte-literal AUMID 'com.marcfargas.gomapi' for plan 10-06 ldflags -X main.aumidOverride to match"
  affects: []
tech_stack:
  added: []
  patterns:
    - "NSIS ApplicationID::Set + Pop $0 + StrCmp return-code check (RESEARCH §Pitfall 2 mitigation)"
    - "NSIS ExecWait 'netsh advfirewall firewall add rule ...' $0 — single-line, program-scoped, continue-on-failure"
    - "Label flow control (StrCmp target + Goto converge) for NSIS conditional branches"
key_files:
  created: []
  modified:
    - src/installer/go-mapi.nsi
  deleted: []
decisions:
  - id: netsh-over-powershell
    summary: "Chose `netsh advfirewall firewall add rule` over `powershell.exe -Command \"New-NetFirewallRule ...\"`. netsh works on all Windows 10+ SKUs without the NetSecurity PowerShell module, keeps the ExecWait to a single line (no PS quote escaping), and matches RESEARCH §Pitfall 4 recommendation."
  - id: program-scoped-not-port-scoped
    summary: "Firewall rule uses `program=\"$INSTDIR\\go-mapi.exe\"` not `localport=NNN`. go-mapi binds 127.0.0.1:0 (ephemeral port), so a port-scoped rule would need the runtime port — impossible at install time. Program scope is narrower AND port-stable: only this specific .exe can receive traffic through this rule, tampering with $INSTDIR requires admin (UAC-gated)."
  - id: aumid-pop-strcmp-required
    summary: "ApplicationID::Set return code is captured via `Pop $0` and checked with `StrCmp $0 \"0\" AumidOk`. RESEARCH §Pitfall 2 explicitly calls out that omitting Pop silently swallows the plugin rc — a missing Pop could mask Action Center persistence regressions."
  - id: continue-on-failure
    summary: "Neither Function uses `Abort`. AUMID stamp failure logs a WARNING DetailPrint and flows to AumidDone via explicit `Goto`; firewall rc is logged but not checked. D-07 spirit: installer continues on soft failures, Pester test (plan 10-05) catches regressions in CI."
  - id: comment-rephrase-no-abort-literal
    summary: "Task 1's acceptance regex checks that the literal word `Abort` does NOT appear inside the CreateShortcutAndAUMID function body (case-sensitive `\\bAbort\\b`). The explanatory comment 'Do NOT Abort — continue install' was rephrased to 'Do NOT halt the installer — continue install' to satisfy the automated check while preserving the intent; the same rephrasing was applied to the AddFirewallRule comment for consistency."
metrics:
  duration: ~5 minutes
  completed_date: 2026-04-20T14:00:00Z
  tasks: 2
  files_created: 0
  files_modified: 1
---

# Phase 10 Plan 03: Start Menu Shortcut + AUMID + Firewall Rule Summary

## One-liner

Replaces the two plan 10-01 stubs in `src/installer/go-mapi.nsi` with real bodies: `CreateShortcutAndAUMID` now creates the all-users Start Menu shortcut at `$SMPROGRAMS\go-mapi.lnk` and stamps PKEY_AppUserModel_ID via the vendored ApplicationID plugin with a proper Pop/StrCmp return-code check, and `AddFirewallRule` now adds a program-scoped inbound Windows Firewall rule named "go-mapi OAuth loopback" via `netsh advfirewall firewall add rule` — closing INST-01 (AUMID stamping half) and INST-06 (firewall preempts RDS first-bind UAC prompt).

## Outcomes

- `src/installer/go-mapi.nsi` `Function CreateShortcutAndAUMID` body: `CreateShortcut` with 9 positional args (link, target, parameters=empty, iconfile, iconindex=0, SW_SHOWNORMAL, keyboardshortcut=empty, description `"go-mapi — MAPI-to-Gmail bridge"` with the em-dash per D-13), followed by `ApplicationID::Set "$SMPROGRAMS\go-mapi.lnk" "${AUMID}"`, `Pop $0`, `StrCmp $0 "0" AumidOk`, WARNING DetailPrint branch, `Goto AumidDone`, `AumidOk:` success DetailPrint, `AumidDone:` convergence label.
- `src/installer/go-mapi.nsi` `Function AddFirewallRule` body: single-line `ExecWait 'netsh advfirewall firewall add rule name="go-mapi OAuth loopback" dir=in program="$INSTDIR\go-mapi.exe" action=allow profile=any' $0` followed by `DetailPrint "firewall add rule rc=$0"`. No `Abort`, no `New-NetFirewallRule`.
- Both Functions gained full explanatory block comments explaining D-refs, plugin ABI, scope rationale, and the cross-plan byte-literal dependencies (rule name matches plan 10-04; AUMID matches plan 10-06).
- The Uninstall section body is untouched — `DetailPrint "stub: Uninstall body — implemented in plan 10-04"` + `DeleteRegKey HKLM ...\Uninstall\${PRODUCT_NAME}` remain verbatim, and `Function un.RestorePreviousMailClient` still has its plan 10-01 stub.

## ApplicationID::Set call shape + rc-check pattern

```nsi
ApplicationID::Set "$SMPROGRAMS\go-mapi.lnk" "${AUMID}"
Pop $0
StrCmp $0 "0" AumidOk
DetailPrint "WARNING: AUMID stamp rc=$0 — Action Center persistence may break"
; Do NOT halt the installer — continue install; Pester test (plan 10-05) will surface this in CI.
Goto AumidDone
AumidOk:
DetailPrint "AUMID stamped: ${AUMID}"
AumidDone:
```

Key correctness properties:

| Property | Implementation | Why |
|----------|----------------|-----|
| Plugin rc captured | `Pop $0` immediately after Set | RESEARCH §Pitfall 2 — omitting Pop silently swallows the rc |
| Success detected by exact string match | `StrCmp $0 "0" AumidOk` | Plugin pushes literal "0" on success, "-1" on error; string comparison avoids int-parse edge cases |
| Flow converges cleanly | `Goto AumidDone` after WARNING branch | Without it, AumidOk: would execute in the WARNING path too |
| Installer continues on failure | No `Abort`; WARNING logged | D-07 spirit; Pester test catches regressions in CI |
| AUMID stays in sync with runtime | `${AUMID}` define (not hardcoded literal) | Single source of truth in the header — changing it propagates to all callers |

## netsh invocation + rationale over PowerShell

```nsi
ExecWait 'netsh advfirewall firewall add rule name="go-mapi OAuth loopback" dir=in program="$INSTDIR\go-mapi.exe" action=allow profile=any' $0
DetailPrint "firewall add rule rc=$0"
```

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `name=` | `"go-mapi OAuth loopback"` | Byte-literal — MUST match plan 10-04's uninstall delete-rule |
| `dir=` | `in` | Loopback listener accepts inbound traffic from 127.0.0.1 |
| `program=` | `"$INSTDIR\go-mapi.exe"` | Narrow scope; survives ephemeral-port allocation |
| `action=` | `allow` | Unblock inbound for this .exe |
| `profile=` | `any` | Applies to all network profiles since loopback is always 127.0.0.1 |
| `localport=` | *(omitted)* | Port is ephemeral (`:0` bind); program scope is port-stable |

**netsh over `powershell.exe -Command "New-NetFirewallRule ..."`:** RESEARCH §Pitfall 4 recommendation. netsh works on all Windows 10+ SKUs without the NetSecurity PowerShell module being installed, and keeps the ExecWait argument to a single line with no PowerShell-specific quote escaping. The double-quotes inside the command line require the whole argument to be single-quoted in NSIS — standard NSIS convention when the command contains `"..."`.

## Rule scoping decision (program= vs localport=)

go-mapi's OAuth loopback server binds `127.0.0.1:0` — the port is ephemeral and different on every sign-in. Three options were possible:

1. **`localport=<fixed-port>`** — would require pinning a port in the Go code. Rejected: breaks if the port is already bound, adds complexity.
2. **`localport=any`** — would allow inbound on ALL ephemeral loopback ports for the entire machine. Rejected: far too broad.
3. **`program="$INSTDIR\go-mapi.exe"`** — CHOSEN. Only this specific .exe can receive inbound traffic through this rule, regardless of which ephemeral port is bound. Tampering with `$INSTDIR` requires admin (UAC-gated), so the rule's authority boundary is the install directory.

Security delta vs the previous v2.0 Inno Setup install: v2.0 had no firewall rule because the Edge extension architecture used no loopback server (it was browser-hosted). v3.0's Wails app uses PKCE loopback OAuth, which is why this rule is new. The addition is minimum-viable surface (single program, not a port range).

## Byte-literal constants that plans 10-04 and 10-06 MUST match

| Constant | Value | Used by plan 10-04 | Used by plan 10-06 |
|----------|-------|--------------------|--------------------|
| Firewall rule name | `go-mapi OAuth loopback` | `netsh advfirewall firewall delete rule name="go-mapi OAuth loopback"` in un.* section | — |
| Shortcut path | `$SMPROGRAMS\go-mapi.lnk` | `Delete "$SMPROGRAMS\go-mapi.lnk"` in un.* section | — |
| AUMID | `com.marcfargas.gomapi` | — | `-X main.aumidOverride=com.marcfargas.gomapi` in release ldflags (+ Pester test reads back from .lnk) |

**Verification prep:** After this plan, `grep -c 'name="go-mapi OAuth loopback"' src/installer/go-mapi.nsi` returns 1 (add-rule only). After plan 10-04 it returns 2 (add + delete). A mismatch between the two rule-name literals would silently leak the rule across uninstalls — the Pester test in plan 10-05 must assert the match.

## Deviations from RESEARCH §Code Examples 6 and 10

**Code Example 6 (CreateShortcut + ApplicationID):** Pasted verbatim with the added block comment header and the label-flow tweak. The plan's inline source already included `Goto AumidDone` after the WARNING branch and the `AumidDone:` convergence label, which matches §Code Example 6 as quoted. No semantic deviation.

**Code Example 10 (netsh firewall):** Pasted verbatim. The plan's inline source spells out the single-quoted argument string with `$0` capturing the exit code, and `DetailPrint "firewall add rule rc=$0"` as the log line — both applied literally. No semantic deviation.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Bug] Rephrased explanatory comment to satisfy automated no-Abort check**
- **Found during:** Task 1 automated verification.
- **Issue:** The plan's inline CreateShortcutAndAUMID source included the comment `; Do NOT Abort — continue install; Pester test (plan 10-05) will surface this in CI.` When the Task 1 verification regex `\bAbort\b` (case-sensitive) ran against the function body, it matched the word "Abort" inside that comment and failed the "No Abort in AUMID function" check — even though the comment's intent was exactly the opposite of containing an `Abort` instruction.
- **Fix:** Rephrased the comment to `; Do NOT halt the installer — continue install; Pester test (plan 10-05) will surface this in CI.` — preserves the authorial intent and the D-07 spirit documentation while satisfying the automated regex. Applied the same rephrasing inside `Function AddFirewallRule` for symmetry (`; Do NOT halt on non-zero rc — group policy may block ...`).
- **Files modified:** `src/installer/go-mapi.nsi` (two comment lines).
- **Commit:** folded into `bf4e1c7` (Task 1 commit).
- **Scope check:** a pure comment rewording; no NSIS instructions changed. The semantic contract "this function does not Abort" is still true — no `Abort` instruction exists in either function body.

No other deviations. Neither of the two Function bodies drifted from the plan's `<action>` block; no files outside `src/installer/go-mapi.nsi` were modified.

## Known Stubs

None introduced by this plan. The two stubs owned by plan 10-03 (`CreateShortcutAndAUMID`, `AddFirewallRule`) had their bodies replaced by this plan. The remaining stubs in `go-mapi.nsi` (Uninstall body, `un.RestorePreviousMailClient`) are plan 10-04's scope and were NOT touched — the stub text `stub: Uninstall body — implemented in plan 10-04` and `stub: un.RestorePreviousMailClient — implemented in plan 10-04` remain verbatim.

## Threat Flags

None. The threat model in `10-03-PLAN.md` (T-10-03-01..05) fully covers the surface introduced by this plan. The implementation's disposition-by-disposition outcome:

| Threat | Disposition | Implementation outcome |
|--------|-------------|------------------------|
| T-10-03-01 EoP (firewall surface) | mitigate | Rule is program-scoped to `$INSTDIR\go-mapi.exe`, not port-scoped. |
| T-10-03-02 Spoofing (AUMID collision) | accept | Documented; no defense change at the installer layer. |
| T-10-03-03 Tampering (plugin silent failure) | mitigate | Pop + StrCmp rc check + WARNING DetailPrint; Pester in plan 10-05 asserts reads-back. |
| T-10-03-04 DoS (netsh GPO block) | accept | rc logged; installer continues; same failure mode as pre-plan. |
| T-10-03-05 Tampering (AUMID mismatch) | mitigate | Installer uses `${AUMID}` define (= `com.marcfargas.gomapi`); matches plan 10-06 ldflags target. |

## Files

### Created

None.

### Modified

- `src/installer/go-mapi.nsi` — `Function CreateShortcutAndAUMID` stub body (1 line) replaced with full implementation (+29 lines including block comment); `Function AddFirewallRule` stub body (1 line) replaced with full implementation (+21 lines including block comment). Net delta: +67 lines, -2 lines across two commits.

### Deleted

None.

## Commits

| Task | Commit  | Message                                                              |
|------|---------|----------------------------------------------------------------------|
| 1    | bf4e1c7 | feat(10-03): implement CreateShortcutAndAUMID with ApplicationID::Set |
| 2    | ab0d3c5 | feat(10-03): implement AddFirewallRule with netsh inbound rule       |

## Metrics

- Duration: ~5 minutes executor wall-time.
- Tasks: 2 / 2 complete.
- Files created: 0.
- Files modified: 1 (`src/installer/go-mapi.nsi`).
- Lines added: ~67; lines deleted: 2 (the two stub DetailPrint lines).
- Tests added: 0 (NSIS script changes; Pester smoke test lands in plan 10-05).
- Build gates: both Task 1 and Task 2 automated `<verify>` regex batteries passed (9 checks + 11 checks respectively). `makensis` compile-sanity run is deferred to plan 10-05 (needs stub .exe + .dll files which are built by the release pipeline).
- Deviations (auto-fixed): 1 (Rule-1 comment rewording to satisfy `\bAbort\b` regex). No architectural or user-gated deviations.

## Self-Check: PASSED

**Files verified on disk:**
- `src/installer/go-mapi.nsi` — present, contains full `Function CreateShortcutAndAUMID` + full `Function AddFirewallRule` bodies (no stub text for either remains)
- `.planning/phases/10-installer-migration/10-03-SUMMARY.md` — present (this file)

**Commits verified in git log:**
- `bf4e1c7` (Task 1 — feat(10-03): implement CreateShortcutAndAUMID with ApplicationID::Set)
- `ab0d3c5` (Task 2 — feat(10-03): implement AddFirewallRule with netsh inbound rule)

**Additional invariants confirmed:**
- Rule-name literal `name="go-mapi OAuth loopback"` appears exactly 1 time in `go-mapi.nsi` (add-rule only; plan 10-04 will add the delete-rule for 2 total).
- `${AUMID}` define in header still equals `com.marcfargas.gomapi` — matches plan 10-06's ldflags target.
- `Function CreateShortcutAndAUMID` body contains no literal word `Abort` (case-sensitive `\bAbort\b`) — verified programmatically.
- `Function AddFirewallRule` body contains no `powershell`, no `New-NetFirewallRule`, no `Abort`.
- Uninstall stubs preserved verbatim: `stub: Uninstall body — implemented in plan 10-04` and `stub: un.RestorePreviousMailClient — implemented in plan 10-04` both still present.
- Scope discipline: ONLY `src/installer/go-mapi.nsi` modified. `git status --short` post-commit shows clean tree.
- No modifications to `STATE.md` or `ROADMAP.md` — orchestrator owns those writes.
