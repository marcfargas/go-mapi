---
phase: 10
slug: installer-migration
status: verified
threats_open: 0
threats_total: 34
threats_closed: 34
asvs_level: 1
block_on: high
created: 2026-04-20
---

# Phase 10 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail for the v3.0 NSIS installer migration (plans 10-01 through 10-06).

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| Installer (admin) → HKLM registry | NSIS process writes machine-wide Mail-handler keys; signed via SignPath in plan 10-06 so elevation surface is gated on publisher identity | MAPI handler metadata; prior `Mail\(Default)` value read for backup |
| Installer (admin) → `%ProgramData%\go-mapi\uninst\` | Admin-elevated write of backup JSON before default-mail-client overwrite | Previous mail-client name (world-readable value) |
| Installer → Microsoft Edge CDN | Bootstrapper `ExecWait` on vendored MicrosoftEdgeWebview2Setup.exe which in turn fetches the runtime from Microsoft; Windows validates Authenticode before running | None (bootstrapper opaque payload) |
| Installer → Windows Shell IPropertyStore (via ApplicationID.dll) | Vendored plugin loaded inside installer process to stamp AUMID on `.lnk` | AUMID constant `com.marcfargas.gomapi` |
| Installer → Windows Firewall | `netsh advfirewall` writes machine-wide inbound rule for `$INSTDIR\go-mapi.exe` | Rule metadata only |
| Wails app → HKLM/HKCU registry | `checkWebView2` read-only probe (QUERY_VALUE) | Runtime presence boolean |
| Uninstaller → Windows Credential Manager | `cmdkey /delete` scoped to current user | — (deletion only) |
| CI workflows → GHA runners (elevated) | `installer-smoke.yml` + `installer-release.yml` run installer as admin on ephemeral VM | AUMID + version strings; OAuth secrets masked by GH Actions |
| Release workflow → SignPath API | Authenticode signing via SignPath Foundation OV certificate | Installer artifact + signing metadata |
| Tag push → GitHub Release asset | Signed `go-mapi-setup.exe` published at stable `latest/download` URL | End-user-visible binary |

---

## Threat Register

### Phase 10-01 — Installer Scaffold

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-10-01-01 | Tampering | MAPI handler HKLM registration clobbers existing Mail default | mitigate | `go-mapi.nsi:85` `Call BackupPreviousMailClient` precedes `go-mapi.nsi:92` `WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "go-mapi"` (delta 7 lines). Upgrade case preserves existing backup. | closed |
| T-10-01-02 | Tampering / supply chain | Vendored `ApplicationID.dll` swap | accept (low) | Plugin committed from connectiblutz/NSIS-ApplicationID v1.1 ReleaseUnicode; git history + PR review; plan 10-06 SignPath signs outer exe. Documented in `src/installer/plugins/x86-unicode/README.md`. | closed |
| T-10-01-03 | Elevation of privilege | Installer runs elevated; bug = privileged code | mitigate | All NSIS string values are compile-time constants; the one system-read value (`Mail\(Default)`) is written to JSON via `FileWrite` only. No `nsExec::Exec` of runtime-variable strings. Verified by full file read. | closed |
| T-10-01-04 | Information disclosure | Backup JSON readable by all users | accept (low) | Contains only HKLM `Mail\(Default)` which is world-readable via `reg query`. ACLs inherit from `%ProgramData%`. | closed |
| T-10-01-05 | Tampering | Stale `src/installer/dist/` v2.0 artifact shipped accidentally | mitigate | `git ls-files src/installer/dist/` empty; `.gitignore:3:dist/` globally ignores it. Local-only build artifact cannot ship via git. | closed |

### Phase 10-02 — WebView2 Bootstrap + Runtime Recovery

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-10-02-01 | Supply chain | Vendored `MicrosoftEdgeWebview2Setup.exe` swap | accept (low) | Committed from Microsoft fwlink; Authenticode-signed by Microsoft; plan 10-06 signs outer installer. | closed |
| T-10-02-02 | Denial of service | Bootstrapper hangs / network failure | mitigate | `go-mapi.nsi:326–349`: 30×2s poll (60s budget) with `PollTimeout` branch (warning log, no `Abort`). `webview2_check.go:29–50` + `main.go:38–43`: dialog + open URL + `os.Exit(1)` fallback. Two-layer recovery. | closed |
| T-10-02-03 | Information disclosure | MessageBox/browser URL leak | accept (low) | Public Microsoft URL; no params, no identifiers. | closed |
| T-10-02-04 | Elevation of privilege | `checkWebView2` HKLM probe | accept (no risk) | `webview2_check.go:39`: `registry.QUERY_VALUE` read-only. | closed |
| T-10-02-05 | Spoofing | MessageBox spoof by local process | accept (low) | `MB_SYSTEMMODAL` flag; not a viable vector per stated threat context. | closed |
| T-10-02-06 | Tampering (build integrity) | Build-tag split regression | mitigate | `webview2_check.go:1` `//go:build !bindings`; `webview2_check_bindings.go:1` `//go:build bindings` no-op stubs. Pattern mirrors `credentials_check.go`. | closed |

### Phase 10-03 — Start Menu Shortcut + AUMID + Firewall Rule

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-10-03-01 | Elevation of privilege | Firewall rule too broad | mitigate | `go-mapi.nsi:422` adds rule scoped `program="$INSTDIR\go-mapi.exe"` (not `localport=`). Replacing the binary at `$INSTDIR` requires admin. | closed |
| T-10-03-02 | Spoofing | AUMID collision | accept (low) | Reverse-domain name `com.marcfargas.gomapi` under marcfargas.com; Windows treats AUMIDs as opaque. | closed |
| T-10-03-03 | Tampering | ApplicationID plugin silent failure | mitigate | `go-mapi.nsi:387–395`: `Pop $0` + `StrCmp $0 "0" AumidOk` + `DetailPrint WARNING`. `installer.Tests.ps1:87–91` item 5 asserts stamped AUMID reads back via `IPropertyStore`. | closed |
| T-10-03-04 | Denial of service | netsh firewall add fails due to GPO | accept | `DetailPrint "firewall add rule rc=$0"` (`go-mapi.nsi:423`); installer continues. Documented as Pitfall 4. | closed |
| T-10-03-05 | Tampering | AUMID mismatch installer vs runtime | mitigate | Installer: `!define AUMID "com.marcfargas.gomapi"`. Runtime: `toast.go:53` `var aumidOverride` + ldflags `-X main.aumidOverride=com.marcfargas.gomapi`. Pester item 5 asserts stamped AUMID equals runtime constant. | closed |

### Phase 10-04 — Uninstaller 10-step Scrub + README Migration Notes

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-10-04-01 | Tampering | Corrupted backup JSON injects HKLM write | mitigate | `go-mapi.nsi:541–546` (`VerifyAndRestore`): `ReadRegStr $5 HKLM "SOFTWARE\Clients\Mail\$1" ""` + `StrCmp $5 "" TryFallbacks`. Missing subkey falls through to fallback chain — no arbitrary write. | closed |
| T-10-04-02 | Information disclosure | cmdkey deletes wrong CredMan target | mitigate | `go-mapi.nsi:474`: `cmdkey /delete:go-mapi:oauth-tokens` (colon form). Target matches `auth.go:27–28` (`keyringService = "go-mapi"`, `keyringUser = "oauth-tokens"`). Pester item 12 asserts no matching entry post-uninstall. Slash form absent. | closed |
| T-10-04-03 | Information disclosure | Multi-user RDS tokens survive uninstall | accept (D-19) | Per-user scrub by design. README documents self-service recovery command. Enumerate-all-profiles deferred. | closed |
| T-10-04-04 | Denial of service | Ordering: ProgramData deleted before restore reads | mitigate | `go-mapi.nsi:452` step 4 `Call un.RestorePreviousMailClient` precedes `go-mapi.nsi:456` step 5 `RMDir /r ... ProgramData\go-mapi\uninst`. | closed |
| T-10-04-05 | Tampering | Firewall rule add/delete name mismatch | mitigate | `go-mapi.nsi:422` add + `go-mapi.nsi:442` delete, both `name="go-mapi OAuth loopback"` (1 occurrence each, byte-for-byte). Pester item 10 asserts rule absent post-uninstall. | closed |
| T-10-04-06 | Tampering | Leftover v2.x artifacts | accept (D-20) | Clean-break migration; README directs v2 users to uninstall v2 first. v2 artifacts benign to v3 (different install location + browser channel). `grep -ci NativeMessagingHosts` = 0. | closed |

### Phase 10-05 — Pester 5 Smoke Test + CI Gate

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-10-05-01 | Information disclosure | OAuth secrets leaked to CI logs | mitigate | `installer-smoke.yml`: no OAuth secrets injected (AUMID-only ldflag at line 83); exclusion rationale documented (lines 33–40). GH Actions auto-masks registered secrets. Forked PRs receive empty strings. | closed |
| T-10-05-02 | Tampering | Malicious PR removes test assertions | accept | PR review gate only; no practical automated defense. | closed |
| T-10-05-03 | Denial of service | Smoke test flakes | mitigate | `AumidReader.ps1:20–105` uses stable `IPropertyStore.GetValue(PKEY_AppUserModel_ID)` (not `Get-StartApps`). 7-day artifact upload with `if: always()` for post-mortem. | closed |
| T-10-05-04 | Tampering | AumidReader swapped for hardcoded-return stub | accept | PR review; inline C# COM primitives (`IPersistFile.Load` + `IPropertyStore.GetValue`) are auditable in diff. | closed |
| T-10-05-05 | Elevation of privilege | Elevated installer on GHA runner | accept | Ephemeral VM; no persistent blast radius. The NSIS script is the thing-under-test. | closed |

### Phase 10-06 — Release Pipeline + SignPath + wails.json Version Authority

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-10-06-01 | Tampering | OAuth secrets leaked via release workflow logs | mitigate | `installer-release.yml:33–35`: env-var injection only. `installer-release.yml:96`: ldflags uses `$env:GOMAPI_OAUTH_CLIENT_SECRET` PowerShell reference — literal value never in YAML. GH Actions auto-masks. | closed |
| T-10-06-02 | Tampering | Unsigned binary slips into signed release | accept (D-24) | Intentional fallback: `installer-release.yml:109` `if: secrets.SIGNPATH_API_TOKEN != ''`. Users see SmartScreen warning; acceptable for OSS. Phase 11 REL-02 owns SmartScreen handling. | closed |
| T-10-06-03 | Tampering | Tag vs wails.json version mismatch | mitigate | `installer-release.yml:64–80`: `ConvertFrom-Json` on `src/app/wails.json`, compares `info.productVersion` to `github.ref_name`; `throw` on mismatch before any SignPath call. | closed |
| T-10-06-04 | Denial of service | SignPath API outage blocks release | mitigate | D-24 unsigned fallback (`installer-release.yml:161–173`); SignPath v2 action retries per vendor docs; `workflow_dispatch` manual re-run with `dry_run: true`. | closed |
| T-10-06-05 | Spoofing | Maintainer account compromise | accept | Out of scope; mitigated at GitHub org level (2FA, branch/tag protection). SignPath per-sign approval available at org level. | closed |
| T-10-06-06 | Tampering | Wrong SignPath project/policy slug | mitigate | `installer-release.yml:120–126,152–158`: `project-slug` and `signing-policy-slug` from repo secrets. SignPath rejects mismatched policy. Setup instructions direct configuration in SignPath dashboard. | closed |
| T-10-06-07 | Tampering | Wails ldflags wrong package path → aumidOverride unset | mitigate | `toast.go:53`: `var aumidOverride string` in `package main`. Both workflows use `-X main.aumidOverride=` (correct prefix per PATTERNS.md §Shared Pattern 4 errata). Acknowledged gap: runtime toast AUMID not exercised by Pester (Phase 9 UAT deferred); ldflags path itself is correct. | closed |

*Status: open · closed*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|-----------|-----------|-------------|------|
| AR-10-01 | T-10-01-02 | ApplicationID.dll vendored from connectiblutz fork; git history + PR review gate re-vendoring. Compensating control: plan 10-06 SignPath Authenticode signs outer installer. | Marc Fargas | 2026-04-20 |
| AR-10-02 | T-10-01-04 | Backup JSON contains only world-readable HKLM value; no PII. ACLs inherit from `%ProgramData%`. | Marc Fargas | 2026-04-20 |
| AR-10-03 | T-10-02-01 | `MicrosoftEdgeWebview2Setup.exe` from Microsoft fwlink; Authenticode-signed by Microsoft; validated by Windows at `ExecWait` time. | Marc Fargas | 2026-04-20 |
| AR-10-04 | T-10-02-03 | Public Microsoft URL; no user identifiers. | Marc Fargas | 2026-04-20 |
| AR-10-05 | T-10-02-04 | `registry.QUERY_VALUE` read-only; unprivileged process — no EoP surface. | Marc Fargas | 2026-04-20 |
| AR-10-06 | T-10-02-05 | Standard Win32 MessageBox has no spoofing resistance; local-malware defense not in scope. | Marc Fargas | 2026-04-20 |
| AR-10-07 | T-10-03-02 | Reverse-domain AUMID under marcfargas.com; Windows treats as opaque. | Marc Fargas | 2026-04-20 |
| AR-10-08 | T-10-03-04 | GPO may block `netsh`; installer continues. Same failure mode pre-plan. Documented as Pitfall 4. | Marc Fargas | 2026-04-20 |
| AR-10-09 | T-10-04-03 | Per-user scrub only (D-19). README provides self-service recovery command `cmdkey /delete:go-mapi:oauth-tokens`. | Marc Fargas | 2026-04-20 |
| AR-10-10 | T-10-04-06 | Clean-break v2→v3 migration (D-20). README directs users to uninstall v2 first. Leftover artifacts benign to v3. | Marc Fargas | 2026-04-20 |
| AR-10-11 | T-10-05-02 | Malicious PR assertion-removal mitigated by PR review only; no practical automated defense. | Marc Fargas | 2026-04-20 |
| AR-10-12 | T-10-05-04 | AumidReader inline-C# stub swap mitigated by PR review; COM primitives auditable in diff. | Marc Fargas | 2026-04-20 |
| AR-10-13 | T-10-05-05 | Elevated installer on ephemeral GHA VM — no persistent blast radius. | Marc Fargas | 2026-04-20 |
| AR-10-14 | T-10-06-02 | Unsigned fallback when `SIGNPATH_API_TOKEN` absent (D-24). SmartScreen warning acceptable for OSS. Phase 11 REL-02 owns SmartScreen UX. | Marc Fargas | 2026-04-20 |
| AR-10-15 | T-10-06-05 | Maintainer compromise mitigated at GitHub org level (2FA + branch/tag protection). SignPath per-sign approval available but outside this plan. | Marc Fargas | 2026-04-20 |

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-04-20 | 34 | 34 | 0 | gsd-security-auditor (sonnet) via /gsd-secure-phase |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-04-20
