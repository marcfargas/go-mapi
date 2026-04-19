# Phase 10: Installer + Migration - Context

**Gathered:** 2026-04-19
**Status:** Ready for planning

<domain>
## Phase Boundary

Ship a signed, single-file NSIS installer (`go-mapi-setup.exe`) that provisions the v3.0 Wails app on a fresh Windows machine: deposits the Go binary + MAPI DLL under `%ProgramFiles%\go-mapi\`, registers `HKLM\SOFTWARE\Clients\Mail\go-mapi` with the DLL path, creates a Start Menu shortcut stamped with AUMID `com.marcfargas.gomapi` (so toast notifications persist in Action Center per Phase 9 NOTIF-04/05), bootstraps the WebView2 Evergreen runtime, adds a Windows Firewall rule for the OAuth loopback port, and ships a Pester 5 smoke test that round-trips install/uninstall on `windows-latest` CI.

Machine-wide install only — admin elevation is mandatory because the MAPI DLL is loaded from system processes via the HKLM Mail-client registration. No per-user install path.

No v2.x migration logic inside the installer: users uninstall v2 themselves before installing v3 (clean-break per PROJECT.md). The installer does NOT probe `%APPDATA%\...\NativeMessagingHosts\`, old v2 install dirs, or the old MAPI key for scrubbing. A one-line note in README + release notes tells v2 users to uninstall v2 first.

Uninstall is a full scrub: binaries, MAPI handler key, AUMID Start Menu shortcut, firewall rule, `%TEMP%\go-mapi\` (best-effort), `%APPDATA%\go-mapi\` (current user, per DPAPI + profile scoping), Windows Credential Manager `go-mapi/oauth-tokens` entry (current user), and restoration of the pre-install default Mail client from the backup JSON.

Scope covers **INST-01 through INST-07**, plus a Phase-10-added runtime recovery path (Wails app detects missing WebView2 at launch, shows a native MessageBox + opens the Microsoft download URL, exits cleanly). Release pipeline (tag push → signed installer attached to GitHub Release at the stable `latest/download/go-mapi-setup.exe` URL) is in scope; actual v3.0.0 tag push is Phase 11.

**Out of scope (belongs elsewhere):**
- Autoupdate check / notify UX (Phase 11 REL-03/REL-04)
- Chrome Web Store / Edge Add-ons unpublish (Phase 11 REL-05)
- Smoke-testing the full install → sign-in → MAPI trigger → draft flow end-to-end (Phase 11 REL-07 + the sandbox-automation todo from Phase 9)
- Installer localization / multi-language (English only for v3.0)
- In-process autoupdate / binary self-replace (rejected by PROJECT.md Out of Scope)

</domain>

<decisions>
## Implementation Decisions

### Installer tooling + layout (INST-01, INST-04)
- **D-01:** NSIS is the installer tool (locked v3.0 seed; supersedes v2.0 Inno Setup). Script lives at `src/installer/go-mapi.nsi`. Rationale: NSIS has a first-class `ApplicationID` plugin for PKEY_AppUserModel_ID stamping, which is the critical primitive for Phase 9's toast persistence requirement.
- **D-02:** Machine-wide install ONLY. `RequestExecutionLevel admin` at the top of the script. Install dir `$PROGRAMFILES64\go-mapi`. No per-user path. UAC prompt is mandatory and acceptable. Rationale: MAPI DLL is loaded from system processes via HKLM Mail-client registration; per-user HKCU MAPI handler registration is not honored by all MAPI callers.
- **D-03:** Output filename is `go-mapi-setup.exe` (no version suffix). The stable GitHub Releases URL `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` resolves the same filename across all releases (ports v2.0 D-04/D-23).
- **D-04:** Installer files deposited in `$INSTDIR`: `go-mapi.exe` (Wails binary), `go-mapi.dll` (MAPI interceptor), and the `ApplicationID.dll` NSIS plugin (at build time only, not shipped). No README/LICENSE in the install directory.

### WebView2 runtime (INST-02)
- **D-05:** Bundle the **online Evergreen bootstrapper** (MicrosoftEdgeWebview2Setup.exe, ~2 MB) inside the NSIS installer. Total installer size target: under 20 MB. Rationale: solo-maintainer simplicity; consumer + most RDS cases covered; the offline ~200 MB bundle is too big for every release asset.
- **D-06:** Runtime presence check via registry (Pitfall 2 guidance): read `HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` (fallback `HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-...}` for 64-bit registry). If absent, invoke the bundled bootstrapper with `/silent /install`, then **poll** the registry key for up to ~60 seconds (handles the documented `/silent /install` timing bug — bootstrapper exits before install completes).
- **D-07:** If the bootstrap still fails after polling (offline/locked-down server), the installer **continues** rather than aborting. Rationale: WebView2 can be uninstalled at any time post-install; the Wails app must already survive missing-runtime at any launch, so shifting the recovery UX entirely to the app removes a failure mode from the installer. Installer logs the failure and writes a note to `$INSTDIR\install.log`.
- **D-08:** **Runtime-missing recovery in the Wails app (NEW Phase 10 scope):** before `wails.Run()` in `src/app/main.go`, detect WebView2 absence via the same HKLM registry check. If absent, show a native Win32 `MessageBoxW` ("WebView2 Runtime is required. Install it from the Microsoft Edge WebView2 page and relaunch go-mapi.") with an OK button, open `https://developer.microsoft.com/en-us/microsoft-edge/webview2/` in the system browser via `github.com/pkg/browser`, then exit cleanly. Build-tag split applies (`credentials_check.go` pattern) so `wailsbindings.exe` introspection does not trigger `os.Exit`. Extracted to a `webview2_check.go` file (plus `_bindings.go` stub) per Phase 8 convention.

### MAPI handler registration (INST-01)
- **D-09:** HKLM registry layout (mirrors v2.0 D-07 with v3 DLL path):
  - `HKLM\SOFTWARE\Clients\Mail\go-mapi\(Default)` = `"go-mapi"`
  - `HKLM\SOFTWARE\Clients\Mail\go-mapi\DLLPath` = `"$INSTDIR\go-mapi.dll"`
  - `HKLM\SOFTWARE\Clients\Mail\(Default)` = `"go-mapi"` (set AFTER the previous-client backup step)

### Previous Mail client backup + restore (INST-05)
- **D-10:** Port v2.0 D-09/D-16 pattern verbatim. Before setting `HKLM\SOFTWARE\Clients\Mail\(Default) = go-mapi`, read the current value and write `%ProgramData%\go-mapi\uninst\previous-mail-client.json` with shape `{ "previousClient": "<name-or-null>", "backedUpAt": "<ISO-8601>" }`. On reinstall/upgrade, if the current default is already `go-mapi`, do NOT overwrite the existing backup (preserve the original).
- **D-11:** Uninstall restoration: if the backup JSON exists AND `(Default)` currently points at `go-mapi`, restore `previousClient` when the target `HKLM\SOFTWARE\Clients\Mail\<name>` subkey still exists; else try fallbacks `Microsoft Outlook`, `Outlook`, `Windows Mail`; else clear `(Default)` to empty string. Matches v2.0 `install.ps1` restore logic.
- **D-12:** `%ProgramData%\go-mapi\uninst\` is created by the installer. ACLs inherit from `%ProgramData%` (SYSTEM + Administrators writable, Users readable). Directory is left in place on upgrade; removed only on full uninstall.

### AUMID + Start Menu shortcut (INST-01, NOTIF-04 install-time)
- **D-13:** Start Menu shortcut at `$SMPROGRAMS\go-mapi.lnk` with `TargetPath = $INSTDIR\go-mapi.exe`, `WorkingDir = $INSTDIR`, `Description = "go-mapi — MAPI-to-Gmail bridge"`.
- **D-14:** Stamp `PKEY_AppUserModel_ID = com.marcfargas.gomapi` on the `.lnk` using the **NSIS `ApplicationID` plugin** (https://nsis.sourceforge.io/ApplicationID_plug-in). Call: `ApplicationID::Set "$SMPROGRAMS\go-mapi.lnk" "com.marcfargas.gomapi"`. Replaces the inline C# + IShellLink + IPropertyStore acrobatics from `scripts/register-dev-aumid.ps1`. Rationale: plugin is standard, well-tested, ships via NSIS packages (`choco install nsis` on `windows-latest` picks it up or installs via explicit step).
- **D-15:** Production AUMID is `com.marcfargas.gomapi` (matches Phase 9 D-06 suggestion; Phase 9 WR-01 established the ldflags-injection pattern). Build-time: `-ldflags "-X github.com/marcfargas/go-mapi/src/app.aumidOverride=com.marcfargas.gomapi"` (planner confirms exact package path against current `aumidOverride` var location). Dev AUMID remains `com.marcfargas.gomapi.dev` via `scripts/register-dev-aumid.ps1`.

### Windows Firewall rule (INST-06)
- **D-16:** On install, create inbound firewall rule: `New-NetFirewallRule -DisplayName "go-mapi OAuth loopback" -Direction Inbound -Program "$INSTDIR\go-mapi.exe" -Action Allow -Profile Any` (invoked via NSIS `Exec` calling `powershell.exe -NoProfile -Command`). Matches Pitfall 4 guidance. Prevents the "first OAuth sign-in hangs on RDS because firewall prompt is on the server console" failure mode.
- **D-17:** On uninstall, remove the rule: `Remove-NetFirewallRule -DisplayName "go-mapi OAuth loopback" -ErrorAction SilentlyContinue`.

### Uninstall cleanup (INST-05)
- **D-18:** Uninstaller removes, in order: (1) firewall rule (D-17), (2) Start Menu shortcut `$SMPROGRAMS\go-mapi.lnk`, (3) MAPI handler key `HKLM\SOFTWARE\Clients\Mail\go-mapi`, (4) restore `(Default)` per D-11, (5) `%ProgramData%\go-mapi\uninst\` (after restore), (6) `%TEMP%\go-mapi\` (best-effort — resolves to the uninstaller's elevated temp view; real users' temp dirs already self-clean via `os.Remove` per privacy model), (7) **`%APPDATA%\go-mapi\`** for the uninstalling user (contains `settings.json` + `app.log`), (8) Windows Credential Manager `go-mapi / oauth-tokens` entry for the uninstalling user (via `cmdkey /delete:go-mapi` or native NSIS call), (9) `$INSTDIR\go-mapi.exe` + `$INSTDIR\go-mapi.dll`, (10) empty `$INSTDIR`.
- **D-19:** **Multi-user caveat (RDS):** because Credential Manager tokens and `%APPDATA%\go-mapi\` are per-user + DPAPI-scoped, the machine-wide uninstaller can only scrub the uninstalling user's copies. Other users on a multi-user machine may retain their own tokens + settings after uninstall. Document this limitation in README + release notes. Matches v2.0 D-15 pragmatism. Enumerate-all-profiles logic is out of scope for v3.0.
- **D-20:** No v2.x artifact cleanup inside the installer or uninstaller. Users uninstall v2 before installing v3. README + release notes carry a one-line "Before installing v3.0: please uninstall any prior go-mapi v2.x from Add/Remove Programs" note.

### Pester 5 smoke test (INST-07)
- **D-21:** Test file: `src/installer/tests/installer.Tests.ps1`. Runs on `windows-latest` via `pwsh`. Describe/Context/It layout. Adapts v2.0 D-17 pattern. **Coverage scope:**
  1. Silent install: `go-mapi-setup.exe /S /D=C:\Program Files\go-mapi` (NSIS silent) exits 0
  2. `$env:ProgramFiles\go-mapi\go-mapi.exe` + `go-mapi.dll` present
  3. HKLM MAPI handler key exists with `DLLPath` value
  4. `$env:ProgramData\go-mapi\uninst\previous-mail-client.json` exists + parses + has `previousClient` + `backedUpAt`
  5. Start Menu shortcut exists AND its AUMID equals `com.marcfargas.gomapi` (via `Shell.Application` COM + `IShellItem2.GetString(PKEY_AppUserModel_ID)` OR via `Get-StartApps` if present; planner picks a stable primitive)
  6. `Get-NetFirewallRule -DisplayName "go-mapi OAuth loopback"` returns a rule
  7. Silent uninstall: `$env:ProgramFiles\go-mapi\uninstall.exe /S` exits 0
  8. Install dir gone (or empty)
  9. MAPI handler key gone
  10. Firewall rule gone
  11. `$env:APPDATA\go-mapi\` gone for the runner user
  12. `cmdkey /list:go-mapi` returns no entries (Credential Manager scrub)
  13. Start Menu shortcut gone
- **D-22:** NOT in Pester scope: toast delivery (deferred to Phase 9's `.planning/todos/pending/2026-04-19-automate-tray-visual-qa-windows-sandbox.md`), live WebView2 UI, bootstrap-failure simulation (the `windows-latest` runner ships with WebView2 preinstalled; simulating absence is non-trivial and flaky). End-to-end install → sign-in → draft flow is Phase 11 REL-07.

### Signing (ports v2.0 D-19/D-20/D-21)
- **D-23:** Two SignPath calls via `SignPath/github-action-submit-signing-request@v1`:
  1. Before `makensis`: sign `go-mapi.exe` + `go-mapi.dll` as one signing request. Signed outputs replace the unsigned staged binaries before `makensis` bundles them.
  2. After `makensis`: sign the produced `go-mapi-setup.exe` as a separate request.
- **D-24:** Gated on `SIGNPATH_API_TOKEN` repo secret. Workflow step uses `if: ${{ secrets.SIGNPATH_API_TOKEN != '' }}`. When missing, the pipeline builds + publishes unsigned. Additional required secrets (same as v2.0 D-21): `SIGNPATH_ORG_ID`, `SIGNPATH_PROJECT_SLUG`, `SIGNPATH_SIGNING_POLICY_SLUG`. Workflow file documents these inline.
- **D-25:** Signing only runs on tag pushes matching `v3.*` (or `v*` per existing convention — planner confirms). Develop/PR builds skip sign entirely.

### Version authority + release workflow
- **D-26:** Version source of truth is `src/app/wails.json` (`info.productVersion`). The CI tag-push job validates that the pushed tag (e.g. `v3.0.0`) matches `wails.json`'s version, then exports `GOMAPI_VERSION=3.0.0` to both `makensis /DGOMAPI_VERSION=3.0.0` (for installer VersionInfo + file naming) and `go build -ldflags "-X main.Version=3.0.0"` (for the Wails binary's `Version` var, already established in Phase 8).
- **D-27:** Release workflow: new file `.github/workflows/installer-release.yml`. Triggers on tag push `v*`. Steps: (1) checkout, (2) set up Go 1.25 + Node 20 + MinGW, (3) `npm run build:interceptor` → DLL, (4) `wails build -ldflags "-X main.Version=$GOMAPI_VERSION -X github.com/marcfargas/go-mapi/src/app.aumidOverride=com.marcfargas.gomapi -X main.oauthClientID=$OAUTH_CLIENT_ID -X main.oauthClientSecret=$OAUTH_CLIENT_SECRET"` → go-mapi.exe, (5) SignPath sign binaries (if token), (6) `choco install nsis` (or cache), (7) `makensis /DGOMAPI_VERSION=$GOMAPI_VERSION src\installer\go-mapi.nsi` → `go-mapi-setup.exe`, (8) SignPath sign installer (if token), (9) `softprops/action-gh-release@v2` attaches `go-mapi-setup.exe` to the GitHub Release. Does NOT modify any existing `release.yml` (scope discipline — strictly additive workflow).
- **D-28:** OAuth client secrets (`GOMAPI_OAUTH_CLIENT_ID`, `GOMAPI_OAUTH_CLIENT_SECRET`) come from repo secrets in the release workflow (they're already needed for any ldflags-injected release build per Phase 8 D-08/D-09).

### Pester smoke-test workflow
- **D-29:** CI workflow `.github/workflows/installer-smoke.yml`. Triggers on `push` to `main`/`develop`, `pull_request`, `workflow_dispatch`. Steps: checkout → build DLL + Wails binary (dev-mode ldflags, no sign) → install NSIS (`choco install nsis`) → `makensis src\installer\go-mapi.nsi` → run Pester: `Invoke-Pester -Configuration @{ Run = @{ Path = 'src/installer/tests/installer.Tests.ps1'; Exit = $true }; Output = @{ Verbosity = 'Detailed' } }`. Blocking gate on per-PR; failure blocks merge.
- **D-30:** Pester 5 is pre-installed on `windows-latest`. No install step needed. Older Pester 4 `-EnableExit` syntax is forbidden.

### Housekeeping
- **D-31:** Delete the v2.0 Inno Setup artifacts outright (no archive). Remove `src/installer/dist/go-mapi-setup.exe` (the built v2.0 artifact). If `src/installer/go-mapi.iss` exists (it doesn't today — only the built `.exe` + a `dist/` dir remain under `src/installer/`), delete it. Git history preserves everything; the v2.0 milestone's `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/` already contains the full plan + summaries, which is the authoritative reference. Phase 10 creates `src/installer/go-mapi.nsi` + `src/installer/tests/installer.Tests.ps1` clean.

### Claude's Discretion
- Exact NSIS UI flow (welcome → license → install-dir → progress → finish) vs. minimalist silent-by-default layout — planner picks, defaulting to the standard ModernUI2 layout with LGPL-3.0 license page.
- Internal section naming inside `go-mapi.nsi`, variable names, helper `Function` names.
- Pester Describe/Context/It naming within the D-21 coverage checklist.
- Exact NSIS `ApplicationID` plugin build-time integration (copy plugin .dll to `$NSISDIR\Plugins` vs. repo-local path) — planner picks whichever keeps CI reproducible.
- The precise PowerShell primitive for verifying AUMID on a .lnk in Pester (`Shell.Application` COM + `GetDetailsOf` vs. direct IShellItem2 via inline C# vs. `Get-StartApps` scrape) — planner picks the most stable one.
- Release notes template shape and `.github/release-template.md` content — modest adaptation of v2.0 D-24 is fine.
- Whether `installer-smoke.yml` reuses a build matrix artifact from `build.yml` or inlines the Wails build — planner picks whichever minimizes CI wall-time.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope + requirements
- `.planning/ROADMAP.md` §"Phase 10: Installer + Migration" — goal, 5 success criteria, dependency on Phase 9
- `.planning/REQUIREMENTS.md` INST-01 through INST-07 (lines 50–56), plus the requirement→phase table at lines 140–146
- `.planning/PROJECT.md` §Current Milestone, §Constraints (Privacy, Distribution, LGPL-3.0), §Key Decisions (v3.0 Wails pivot, clean-break migration, NSIS choice)
- `.planning/STATE.md` — Phase 9 close-out decisions that Phase 10 consumes (AUMID ldflags pattern, Wails binary build flags, invalidation guard pattern)

### Prior phase context (installer-relevant)
- `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/03-CONTEXT.md` — v2.0 installer context. D-07/D-09/D-13/D-14/D-16/D-17/D-19/D-20/D-21/D-23 are ported into this phase's D-09/D-10/D-11/D-16/D-17/D-18/D-23/D-24/D-25/D-03
- `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/03-01-PLAN.md` through `03-04-PLAN.md` — plan-level reference for how an installer phase decomposes (4 plans in v2.0; Phase 10 may need more due to WebView2 + AUMID + runtime-recovery additions)
- `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/03-01-SUMMARY.md` through `03-04-SUMMARY.md` — implementation notes, Pester test structure, Pascal Script → NSIS translation hints
- `.planning/phases/08-oauth-credentials/08-CONTEXT.md` — OAuth ldflags-injection pattern (D-08/D-09/D-10) consumed by release workflow D-27/D-28
- `.planning/phases/09-queue-automode-toasts/09-CONTEXT.md` — AUMID production suggestion D-06, ldflags-injectable pattern (Phase 9 WR-01), toast tag/group removal scheme D-08, dev-AUMID helper handoff
- `.planning/phases/09-queue-automode-toasts/09-HUMAN-UAT.md` — deferred UAT items that Phase 10 Pester does NOT cover (tracked for sandbox-automation todo)

### Research artifacts Phase 10 consumes
- `.planning/research/PITFALLS.md` §Pitfall 2 (WebView2 bootstrapper timing bug), §Pitfall 4 (OAuth loopback firewall), §Pitfall 9 (clean-break migration orphans — noted but intentionally not mitigated in installer per D-20), §Pitfall 10 (SmartScreen reputation + SignPath gating)
- `.planning/research/FEATURES.md` §4 Installer + Migration (if present) — feature-level requirements that complement REQUIREMENTS.md

### Reusable patterns in the current repo
- `scripts/register-dev-aumid.ps1` — inline C# + IShellLink + IPropertyStore reference for AUMID stamping (kept for dev path; production path uses NSIS `ApplicationID` plugin per D-14)
- `scripts/unregister-dev-aumid.ps1` — uninstall counterpart for dev shortcut (Pester uninstall logic mirrors this for the prod shortcut)
- `src/app/auth_credentials.go` + `src/app/credentials_check.go` + bindings-tag sibling — build-tag split pattern for fatal startup guards (D-08 WebView2 runtime recovery adopts this exact pattern)
- `src/app/main.go` — current Wails entry; D-08 adds the WebView2 registry check before `wails.Run`

### Build + release infrastructure
- `src/app/wails.json` — version authority per D-26; `info.productVersion` field is the source of truth
- `.github/workflows/build.yml` — existing per-PR build; Phase 10 may consume its artifacts via `workflow_call` or duplicate the build steps in `installer-smoke.yml`
- `src/app/package.json` + root `package.json` — npm workspace layout (Phase 8.1 confirmed `["src/app", "src/app/frontend"]`). Installer does not touch npm.

### Official documentation
- `https://nsis.sourceforge.io/Main_Page` — NSIS reference
- `https://nsis.sourceforge.io/ApplicationID_plug-in` — PKEY_AppUserModel_ID stamping plugin (D-14)
- `https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution` — WebView2 distribution guidance (Evergreen vs Fixed Version vs bootstrapper)
- `https://learn.microsoft.com/en-us/windows/win32/shell/appids` — AUMID specification + PKEY_AppUserModel_ID property
- `https://docs.signpath.io/artifact-configuration/signing-action` — SignPath GitHub Action parameters (D-23)
- `https://pester.dev/docs/introduction/installation` — Pester 5 on windows-latest
- `https://developer.microsoft.com/en-us/microsoft-edge/webview2/` — user-facing download URL opened by D-08 runtime-missing recovery

### Project conventions
- `CLAUDE.md` — Windows 10/11 only, LGPL-3.0, privacy-first, no telemetry, Go 1.25, Wails v2.12.0
- User global `git-workflow.md` — default branch `develop`, conventional commits (`feat`, `fix`, `docs`, `chore`, `ci`)
- User global `lockfile-discipline.md` — if any `npm install` runs during phase, commit lockfile alongside

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/register-dev-aumid.ps1` — complete reference for AUMID stamping on a `.lnk` via inline C# + IShellLink + IPropertyStore. The production path uses the NSIS `ApplicationID` plugin instead (simpler), but this script stays in the repo as the dev-AUMID primitive. Pester AUMID verification logic in D-21 item 5 may port the query-side of this script's PKEY_AppUserModel_ID read.
- `scripts/unregister-dev-aumid.ps1` — uninstall counterpart; Pester uninstall-phase AUMID-gone check mirrors the query it does.
- `src/app/auth_credentials.go` + `credentials_check.go` + the `_bindings.go` stub — proven build-tag split pattern for a fatal startup guard. D-08 WebView2 recovery adopts this verbatim (`webview2_check.go` + `webview2_check_bindings.go`).
- `src/app/auth.go` — `oauthClientID`/`oauthClientSecret` ldflags-injection pattern (Phase 8 D-08/D-09) is reused by the release workflow D-27 alongside the new AUMID + Version injections.
- `src/app/aumidOverride` (exact package path TBD — planner grep-confirms; Phase 9 WR-01 established the var) — Phase 10 release workflow passes `-X <pkg>.aumidOverride=com.marcfargas.gomapi` per D-15.
- v2.0 Inno Setup PLAN/SUMMARY set at `.planning/milestones/v2.0.0-phases/03-inno-setup-installer-signing-distribution/` — full proven implementation structure (registry layout, Pester coverage, SignPath gating, release workflow) ports directly to NSIS.

### Established Patterns
- `windows-latest` runners with `pwsh` shell. Pester 5 pre-installed. Chocolatey available for installing NSIS (`choco install nsis --no-progress -y`).
- Build scripts read version from a single manifest (v2.0: `package.json`; v3.0: `wails.json`) and pass via `-ldflags` / `/D` defines. Release workflow is tag-triggered on `v*`.
- Wails binary is built with `wails build -platform windows/amd64` from `src/app/`; frontend assets are embedded via `go:embed`.
- Build-tag split is mandatory for any `os.Exit`-capable startup guard in `main`-level files (so `wailsbindings.exe` introspection does not abort). Applies to D-08.
- MAPI DLL is produced by `npm run build:interceptor` (MinGW + CMake) → `src/interceptor/build/bin/go-mapi.dll`. Installer stages this path.
- SignPath GitHub Action is gated on secret presence; pipeline falls back to unsigned publish when secrets are absent (v2.0 D-20; carries forward unchanged).

### Integration Points
- Installer reads from (at `makensis` time): `src/interceptor/build/bin/go-mapi.dll`, `src/app/build/bin/go-mapi.exe`, `src/installer/MicrosoftEdgeWebview2Setup.exe` (committed bootstrapper, ~2 MB; verify LGPL/MS redistribution terms allow — this is Microsoft's public redistributable bootstrapper, freely redistributable per MS terms).
- Installer writes at install time: `$PROGRAMFILES64\go-mapi\{go-mapi.exe, go-mapi.dll, uninstall.exe}`, `HKLM\SOFTWARE\Clients\Mail\go-mapi`, `HKLM\SOFTWARE\Clients\Mail\(Default)`, `%ProgramData%\go-mapi\uninst\previous-mail-client.json`, `$SMPROGRAMS\go-mapi.lnk` (with AUMID stamped), Windows Firewall rule `go-mapi OAuth loopback`.
- Uninstaller writes: removes everything from the install-time list plus `%APPDATA%\go-mapi\` (current user), Credential Manager `go-mapi` entries (current user), `%TEMP%\go-mapi\` (best-effort).
- Release workflow writes: GitHub Releases asset `go-mapi-setup.exe` via `softprops/action-gh-release`; does NOT touch any existing workflow file.

</code_context>

<specifics>
## Specific Ideas

- **NSIS ApplicationID plugin usage:** `ApplicationID::Set "$SMPROGRAMS\go-mapi.lnk" "com.marcfargas.gomapi"` is the full call. Plugin ships a `.dll` that goes into `$NSISDIR\Plugins` (or a repo-local `src/installer/plugins/` referenced via `!addplugindir`). Document the install step in the Pester CI workflow so the runner has it before `makensis`.
- **WebView2 registry check (Go + NSIS must match):** 64-bit app, so check the 64-bit registry view first: `HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`. Fall back to WOW6432Node for safety: `HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`. Value to read: `pv` (the installed runtime version string). Non-empty → runtime present.
- **WebView2 bootstrapper invocation:** `ExecWait '"$INSTDIR\WebView2Setup.exe" /silent /install' $0`. Do NOT trust the exit code alone — after the Exec returns, poll the registry key every 2 seconds for up to 60 seconds. The bootstrapper itself downloads ~200 MB in the background; polling is the only reliable completion signal (GitHub issue MicrosoftEdge/WebView2Feedback#1349).
- **Silent install switches for NSIS:** `/S` is the NSIS silent flag (note: case-sensitive, capital S). `/D=C:\Program Files\go-mapi` overrides install dir (NSIS convention: `/D=` must be LAST argument, no quotes even with spaces in the path). Uninstaller inherits `/S`.
- **Credential Manager scrub from NSIS:** `ExecWait 'cmdkey /delete:go-mapi'` works but only removes the default `go-mapi` target. Our actual keyring entry is `service=go-mapi`, `user=oauth-tokens` → Windows stores this as target `go-mapi/oauth-tokens` (zalando/go-keyring convention). Planner confirms the exact target-name string by reading `.planning/phases/08-oauth-credentials/` or running `cmdkey /list:go-mapi*` on a populated dev machine.
- **Firewall rule via NSIS:** Use `ExecWait 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "New-NetFirewallRule ..."'`. Alternative: `netsh advfirewall firewall add rule` (older, no reboot required, available on all Windows 10+). Planner picks whichever keeps the NSIS script shorter.
- **Previous-Mail-client JSON shape stays identical to v2.0:** `{"previousClient":"<name-or-null>","backedUpAt":"<ISO-8601>"}` — NO schema drift. Uninstaller reads the same shape.
- **Pester AUMID verification primitive (candidates):**
  - `Shell.Application` COM + folder `Start Menu\Programs` + `GetDetailsOf(item, 156)` (AUMID column index varies by Windows build — flaky)
  - Inline C# + `IShellLink` + `IPropertyStore` + `GetValue(PKEY_AppUserModel_ID)` — matches the `register-dev-aumid.ps1` stamp side; most reliable
  - `Get-StartApps -Name "go-mapi"` returns an object with an `AppID` property — simplest; cmdlet available on Windows 10+. Planner evaluates.
- **NSIS + PowerShell interop gotcha:** `pwsh` vs `powershell` — `windows-latest` has both; the installer must call `powershell.exe` (Windows PowerShell 5.1) because `pwsh` (PS7) is not guaranteed on end-user machines even though it's on the runner. The firewall rule + Credential Manager calls use Windows PowerShell.
- **Backup JSON timing:** the backup MUST happen BEFORE setting `(Default) = go-mapi` (so the "previous client" is captured correctly). This is the same ordering bug-avoidance as v2.0.

</specifics>

<deferred>
## Deferred Ideas

- **v2.x → v3 automated migration.** Rejected for this phase per user decision. Clean-break stays: users uninstall v2 first. If friction reports surface post-v3.0 ship, a follow-up migration-helper phase can be added.
- **Enumerate-all-profiles uninstall cleanup.** Scrubbing per-user Credential Manager + `%APPDATA%\go-mapi\` for every user on a multi-user RDS host. Out of scope; limitation documented per D-19.
- **Bundle offline WebView2 standalone.** Considered for air-gapped RDS. Rejected for default installer (~200 MB per release asset too expensive). Could ship as a separate `go-mapi-setup-offline.exe` in a later phase if demand emerges.
- **Bootstrap-failure simulation in Pester.** Rejected as flaky for the `windows-latest` runner (WebView2 preinstalled, non-trivial to mock absent). Manual verification or the sandbox-automation todo covers this path.
- **Installer localization (non-English).** English-only for v3.0 (matches PROJECT.md user rule for external projects).
- **In-process autoupdate / binary self-replace.** Already rejected by PROJECT.md Out of Scope + Pitfall 8. Phase 11 REL-03/REL-04 does notify-only autoupdate (re-run installer).
- **SmartScreen reputation submission to Microsoft WDSI.** Tracked by PROJECT.md + Pitfall 10. Belongs in the release checklist (Phase 11 REL-02), not in Phase 10 installer construction.
- **End-to-end install → sign-in → MAPI trigger → draft test on clean Windows.** Phase 11 REL-07 scope. Phase 9's sandbox-automation todo owns the tooling side.
- **Toast delivery verification in CI.** Phase 9 UAT item deferred to `.planning/todos/pending/2026-04-19-automate-tray-visual-qa-windows-sandbox.md`. Not re-raised in Phase 10.

</deferred>

---

*Phase: 10-installer-migration*
*Context gathered: 2026-04-19*
