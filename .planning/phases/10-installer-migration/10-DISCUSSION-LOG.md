# Phase 10: Installer + Migration - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-19
**Phase:** 10-installer-migration
**Areas discussed:** WebView2 bootstrap, Uninstall cleanup depth, Pester smoke test scope, Version + release flow, src/installer/ housekeeping, AUMID stamping, Multi-user caveat, Signing pipeline
**Gray areas deferred upfront by user:** v2.x migration (collapsed to "none"), Per-user vs machine-wide (collapsed to "machine-wide only")

---

## Upfront gray area selection

| Option | Description | Selected |
|--------|-------------|----------|
| WebView2 bootstrap | Online bootstrapper vs offline bundle vs hybrid; failure-mode UX | ✓ |
| Per-user vs machine-wide | Elevation model; HKCU vs HKLM; install path | ✓ (collapsed to locked: machine-wide only, per MAPI DLL registration) |
| v2.x migration UX | Silent scrub vs interactive; which paths | ✓ (collapsed to locked: no migration — users uninstall v2 themselves) |
| Uninstall cleanup depth | OAuth token, %APPDATA%, firewall rule, previous-Mail-client restore | ✓ |

**User's choice:** "WebView2 bootstrap, Uninstall cleanup depth, No migration. people uninstall v2 and then install v3.; install must be machine-wine because of the MAPI DLL registration"
**Notes:** Two areas were answered inline (migration + per-user/machine-wide), simplifying the phase scope significantly before any deep-dive.

---

## WebView2 bootstrap

| Option | Description | Selected |
|--------|-------------|----------|
| Online bootstrapper only | 2 MB bundled bootstrapper, poll registry for completion, abort with link on failure | ✓ |
| Offline standalone only | ~200 MB bundled, works air-gapped | |
| Hybrid — two installers | Ship both consumer (online) and enterprise (offline) | |
| Detect-only, no bundled bootstrapper | Abort with link; user installs WV2 themselves | |

**User's choice:** Online bootstrapper only
**Notes:** Chosen for solo-maintainer simplicity; covers consumer + most RDS cases.

### Bootstrap failure UX

| Option | Description | Selected |
|--------|-------------|----------|
| Abort with downloadable link | Dialog + clean rollback + non-zero exit | |
| Continue install, defer runtime to first launch | Wails app handles missing WV2 at any launch | ✓ |
| Prompt user for offline .exe path | NSIS UI browse + run inline | |

**User's choice:** Continue, defer runtime to launch
**Notes:** "It could happen that a user uninstalls webview2 at any time, so the runtime has to be able to recover from that and re-require webview2 install." This expanded the scope — missing-WebView2 recovery is now a permanent app concern, not just an install-time concern.

### Runtime recovery scope

| Option | Description | Selected |
|--------|-------------|----------|
| In scope for Phase 10 | Add registry check + MessageBox + browser-open + clean exit before wails.Run | ✓ |
| Defer to a later small phase | Track as seed/todo for future | |
| Rely on Wails default error | Accept whatever Wails v2 surfaces | |

**User's choice:** In scope for Phase 10
**Notes:** Keeps the install → launch loop coherent; prevents Pitfall 2's silent-failure mode.

---

## Uninstall cleanup depth

### OAuth token removal

| Option | Description | Selected |
|--------|-------------|----------|
| Remove it | Full scrub — credential manager entry deleted | ✓ |
| Keep it | Preserve for reinstall convenience | |

**User's choice:** Remove it

### %APPDATA%\go-mapi\ removal

| Option | Description | Selected |
|--------|-------------|----------|
| Remove | Settings + log both gone | ✓ |
| Keep app.log, remove settings.json | Partial scrub | |
| Keep both | Preserve for reinstall | |

**User's choice:** Remove

### Firewall rule

| Option | Description | Selected |
|--------|-------------|----------|
| Remove | Clean scrub counterpart to install-time New-NetFirewallRule | ✓ |
| Keep | Orphaned rule tied to dead path | |

**User's choice:** Remove

### Previous-MAPI-client backup + restore

| Option | Description | Selected |
|--------|-------------|----------|
| Keep the v2.0 pattern | Backup JSON on install, restore on uninstall | ✓ |
| Drop it — always clear (Default) | Simpler, user-hostile | |
| Don't touch (Default) at install either | Install doesn't actually register as default Mail client | |

**User's choice:** Keep the v2.0 pattern

---

## Check-in: more areas or write context?

**User's choice:** More gray areas

---

## Pester smoke test scope

| Option | Description | Selected |
|--------|-------------|----------|
| Full round-trip + AUMID + firewall | 13-item coverage list incl AUMID stamp + firewall rule + cred-mgr + APPDATA + backup JSON | ✓ |
| Minimal — install/uninstall round-trip only | Drop AUMID + firewall + MAPI restore | |
| Full + bootstrap-failure branch | Adds mocked WV2-absent variant | |

**User's choice:** Full round-trip + AUMID + firewall
**Notes:** Toast delivery + live WebView2 UI explicitly excluded — deferred to the Phase 9 sandbox-automation todo.

---

## Version authority + release workflow

| Option | Description | Selected |
|--------|-------------|----------|
| src/app/wails.json + tag-triggered installer-release.yml | Version from wails.json; new yml separate from any release.yml | ✓ |
| Root package.json version field | v2.0 D-03 pattern — but root package.json is now an npm workspace manifest | |
| Git tag only, no file version | Simpler but wails.json goes stale | |

**User's choice:** src/app/wails.json + tag-triggered installer-release.yml

---

## src/installer/ housekeeping

| Option | Description | Selected |
|--------|-------------|----------|
| Archive v2.0 .iss + .exe + delete | Move to .planning/milestones/, delete from src/installer/ | |
| Delete outright, no archive | Git history preserves; .planning/milestones already has the full plan docs | ✓ |
| Leave in place alongside NSIS files | Both coexist | |

**User's choice:** Delete outright, no archive

---

## AUMID + Start Menu shortcut stamping

| Option | Description | Selected |
|--------|-------------|----------|
| NSIS ApplicationID plugin | Standard plugin for PKEY_AppUserModel_ID stamping | ✓ |
| Port inline C# via PowerShell | Reuse register-dev-aumid.ps1's C# approach via NSIS Exec | |
| Compile a tiny helper exe | Ship a helper binary | |

**User's choice:** NSIS ApplicationID plugin

---

## Multi-user caveat handling on uninstall

| Option | Description | Selected |
|--------|-------------|----------|
| Document + best-effort current-user only | Uninstaller scrubs current-user state; documents multi-user limitation | ✓ |
| Iterate all user profiles | Enumerate HKEY_USERS + each profile's APPDATA | |
| Leave per-user state entirely, scrub only machine-wide | Simpler, contradicts "nothing remains" | |

**User's choice:** Document + best-effort current-user only

---

## Signing pipeline

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, port v2.0 D-19/D-20/D-21 verbatim | Two sign calls, gated on SIGNPATH_API_TOKEN, unsigned fallback | ✓ |
| Installer-only signing | Skip inner-binary sign | |
| Gate on exact release tag | Sign only on v-prefixed tag pushes | |

**User's choice:** Yes, port v2.0 D-19/D-20/D-21 verbatim

---

## Final check-in

**User's choice:** I'm ready for context

---

## Claude's Discretion

- NSIS UI page layout (ModernUI2 welcome → license → install-dir → progress → finish vs. minimalist)
- Internal NSIS variable names, function names, section names
- Pester Describe/Context/It naming
- ApplicationID plugin build-time layout (repo-local plugin dir vs $NSISDIR\Plugins)
- PowerShell primitive for Pester AUMID verification (Shell.Application COM vs inline C# vs Get-StartApps)
- Release notes template content
- Whether installer-smoke.yml shares a build artifact with build.yml or inlines the Wails build

## Deferred Ideas

- v2.x → v3 automated migration (rejected; users uninstall v2 first)
- Enumerate-all-profiles uninstall cleanup
- Bundled offline WebView2 standalone installer variant
- Bootstrap-failure simulation in Pester
- Installer localization (non-English)
- In-process autoupdate
- SmartScreen WDSI submission (Phase 11 scope)
- End-to-end install → sign-in → draft flow test (Phase 11 REL-07 + sandbox-automation todo)
- Toast delivery verification in CI (sandbox-automation todo)
