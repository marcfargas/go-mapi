# Phase 3: Inno Setup Installer + Signing + Distribution - Context

**Gathered:** 2026-04-10
**Status:** Ready for planning
**Mode:** Executor-derived (phase spec locked in ROADMAP + REQUIREMENTS + Phase 1 handoff)

<domain>
## Phase Boundary

Ship a single-click, signed-when-possible Windows installer that a non-technical user can download from a stable GitHub Releases URL and install with one UAC prompt. The installer must register go-mapi as a Mail client for the MAPI handler path and as a native messaging host for all five Chromium-family browsers (Chrome, Edge, Chromium, Brave, Vivaldi). Signing is best-effort: when the SignPath API token is present, the DLL and host are signed before being bundled into the installer and the installer itself is signed post-build; when the token is absent, the pipeline falls back to an unsigned installer so the release can ship regardless of SignPath approval latency.

Scope is INST-01..07, SIGN-02..05, and the EXT-07 URL swap. The phase runs in parallel with Phase 2 (Extension Install UX). Phase 2 will write `InstallPrompt.tsx` with a placeholder `INSTALLER_DOWNLOAD_URL` constant; EXT-07 is the one-line swap to the final stable URL. Because Phase 2 hasn't written the file yet in this worktree, EXT-07 becomes a merge-time follow-up for the Phase 4 reviewer if `InstallPrompt.tsx` is not present at execute time.

Explicit non-goals for this phase:
- Actually filing the SignPath Foundation application (deferred to Marc per Phase 1 handoff `.continue-here.md`).
- Publishing a real GitHub Release (the release workflow is tag-triggered; no tag is pushed in this phase).
- Cross-compiling Go/C++ or touching the existing build scripts beyond consuming their outputs.
- Modifying extension source files beyond the EXT-07 one-line URL swap.
- Writing Go/TS/C++ tests beyond the Pester installer smoke test (Phase 4 owns the rest).
- A blegal.dev mirror URL (v2 requirement DIST-01, explicitly deferred).
- Edge Add-ons Store publication, macOS/Linux, tray icon, telemetry (all explicit out-of-scope per REQUIREMENTS.md).

</domain>

<decisions>
## Implementation Decisions

### Installer tooling (INST-01)
- **D-01:** Inno Setup 6 is the installer tool. REQUIREMENTS.md out-of-scope table explicitly rejects WiX / NSIS / MSIX / InstallShield / Advanced Installer in favor of Inno Setup for this stack. License is permissive (Inno Setup is free for any use including commercial) and LGPL-compatible.
- **D-02:** The script lives at `src/installer/go-mapi.iss`. Pascal Script `[Code]` section handles manifest template rendering, previous-Mail-client backup, and uninstall cleanup that the declarative sections can't express.
- **D-03:** Version is read from root `package.json` via an Inno Setup `#define AppVersion GetEnv("GOMAPI_VERSION")` fallback to a literal from the `.iss` header. CI passes `GOMAPI_VERSION` as an environment variable before invoking `iscc.exe`. This keeps version in one place (`package.json`) and avoids a second version-update workflow.
- **D-04:** Output filename is `go-mapi-setup.exe` (no version suffix in the filename) so the stable GitHub Releases URL resolves to the same filename across all releases. `OutputBaseFilename=go-mapi-setup`. Inno Setup appends `.exe` automatically.

### Install layout (INST-02, INST-04)
- **D-05:** Install directory is `{pf}\go-mapi` (Inno Setup shorthand for `%ProgramFiles%\go-mapi`). PrivilegesRequired=admin → single UAC prompt.
- **D-06:** Binaries copied: `go-mapi.dll` and `go-mapi-host.exe` into `{app}`. No additional files (no README, no LICENSE in the install dir — those live at the install-time source).
- **D-07:** MAPI handler registry entries written to `HKLM\SOFTWARE\Clients\Mail\go-mapi` with `(Default)` = `"go-mapi"` and `DLLPath` = `{app}\go-mapi.dll`. The `HKLM\SOFTWARE\Clients\Mail` `(Default)` value is set to `go-mapi` to make it the active default Mail client, AFTER the previous-client backup step (D-09) runs.
- **D-08:** Per-user state and the `%TEMP%\go-mapi\` runtime directory are NOT written by the installer — the native host creates `%TEMP%\go-mapi\` at first run. All installer-written state lives under HKLM and `%ProgramData%\go-mapi\` (machine-wide). This satisfies INST-04's "no per-user state" clause.

### Previous Mail client backup (INST-05)
- **D-09:** Before setting `HKLM\SOFTWARE\Clients\Mail\(Default)` to `go-mapi`, the installer reads the current value and writes a JSON file at `%ProgramData%\go-mapi\uninst\previous-mail-client.json`. JSON shape: `{ "previousClient": "<string-or-null>", "backedUpAt": "<ISO-8601>" }`. If the current default is already `go-mapi` (reinstall/upgrade), the backup file is NOT overwritten — we want to preserve the original backup across upgrades.
- **D-10:** The backup directory `%ProgramData%\go-mapi\uninst\` is created by the installer with ACLs inherited from `%ProgramData%` (writable by SYSTEM and Administrators, readable by Users). This directory is left in place on upgrade and only removed on full uninstall.

### Browser registry trees (INST-03)
- **D-11:** One shared manifest file at `%ProgramData%\go-mapi\com.gomapi.host.json` is rendered by the installer from `src/native-host/manifests/com.gomapi.host.chrome.json.tmpl` via Pascal Script `StringChange`. Placeholders replaced: `{{HOST_PATH}}` → `{app}\go-mapi-host.exe` (with JSON-escaped backslashes, matching `install.ps1`'s Render-ManifestTemplate behavior), `{{EXTENSION_ID}}` → the published Chrome Web Store extension ID.
- **D-12:** Extension ID during Phase 3: the installer reads the extension ID from a Pascal Script constant at the top of the `[Code]` section. The constant defaults to the placeholder used by `install.ps1` (`PLACEHOLDER_EXTENSION_ID_32CHR`) until the Chrome Web Store listing is published. A single-point edit updates it for release. This matches the phased rollout — extension ID is finalized when the CWS listing goes live, separately from the installer code.
- **D-13:** Five browser registry trees, all under HKLM (INST-04: no per-user state):
  - Chrome:   `HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host`
  - Chromium: `HKLM\SOFTWARE\Chromium\NativeMessagingHosts\com.gomapi.host`
  - Edge:     `HKLM\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host`
  - Brave:    `HKLM\SOFTWARE\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.gomapi.host`
  - Vivaldi:  `HKLM\SOFTWARE\Vivaldi\NativeMessagingHosts\com.gomapi.host`
  Each key's `(Default)` value is the absolute path `%ProgramData%\go-mapi\com.gomapi.host.json`. All five are written unconditionally from day one — not stretch-goaled (per ROADMAP Phase 3 success criterion #2).

### Uninstall (INST-06)
- **D-14:** Uninstall removes, in this order: (1) the five browser registry trees from D-13, (2) the MAPI handler key `HKLM\SOFTWARE\Clients\Mail\go-mapi`, (3) the shared manifest file `%ProgramData%\go-mapi\com.gomapi.host.json`, (4) `%TEMP%\go-mapi\` leftover email JSON files (best-effort — the runtime directory is per-user so this only cleans the SYSTEM user's copy; see D-15), (5) restores `HKLM\SOFTWARE\Clients\Mail\(Default)` from the backup JSON if it currently points at `go-mapi`, (6) removes `%ProgramData%\go-mapi\uninst\previous-mail-client.json` and the `uninst` directory, (7) deletes the DLL and host binary from `{app}` and removes the empty install directory.
- **D-15:** `%TEMP%\go-mapi\` cleanup is best-effort. The installer runs as Administrator, so `%TEMP%` resolves to the SYSTEM account's temp directory, not the user's. Real-user `%TEMP%\go-mapi\` directories can't be cleaned from the uninstaller without iterating all user profiles, which is out of scope for v2.0.0. The Pascal `DeleteDir` call against `ExpandConstant('{tmp}')` or `GetTempDir` handles whichever temp directory the installer sees. This mirrors the documented privacy-first behavior: runtime files are already deleted by the native host on processing (`os.Remove`), so leftovers only exist if the host crashed or was killed mid-run.
- **D-16:** Default Mail client restoration logic matches `install.ps1`: if backup file exists and the stored `previousClient` points at an existing `HKLM\SOFTWARE\Clients\Mail\<name>` subkey, restore it; otherwise try fallbacks `Microsoft Outlook`, `Outlook`, `Windows Mail` in order; otherwise clear `(Default)` to empty string.

### Pester smoke test (INST-07)
- **D-17:** Pester 5 test file at `src/installer/tests/installer.Tests.ps1`. Runs on `windows-latest` GitHub Actions runner via `pwsh`. Does NOT require a clean VM — uses `Describe`/`Context`/`It` blocks and `BeforeAll`/`AfterAll` for setup/teardown. Tests: (a) silent install via `go-mapi-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=install.log` exit 0, (b) DLL file present at `${env:ProgramFiles}\go-mapi\go-mapi.dll`, (c) host binary present, (d) MAPI handler key exists with `DLLPath` value, (e) all five browser registry keys exist with the shared manifest path, (f) shared manifest file exists and parses as JSON, (g) backup JSON exists and has the required fields, (h) silent uninstall via `"${env:ProgramFiles}\go-mapi\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART` exit 0, (i) all five browser registry keys gone, (j) MAPI handler key gone, (k) install dir gone (or empty).
- **D-18:** The Pester test is driven by a new GitHub Actions workflow `.github/workflows/installer-smoke.yml` that depends on a successful build of the binaries (reuses `build.yml` as `workflow_call` where possible, or downloads the build artifacts and runs `iscc.exe` + the Pester test in one job). To keep the diff minimal and test time low, the smoke-test job builds the installer inline within a single job: check out, download build artifacts (from a prior `build.yml` run or a local build step), invoke `iscc.exe`, run Pester against the produced `go-mapi-setup.exe`. The workflow triggers on `push` to `main`/`develop`, on `pull_request`, and on `workflow_dispatch`.

### Signing (SIGN-02, SIGN-03)
- **D-19:** The signing pipeline uses `SignPath/github-action-submit-signing-request@v1` per REQUIREMENTS.md line 44. Two sign calls:
  1. Before `iscc.exe`: sign `go-mapi.dll` and `go-mapi-host.exe` together as a single signing request (SignPath allows multiple files per request). The signed artifacts replace the unsigned ones in the staging directory that `iscc.exe` reads from.
  2. After `iscc.exe`: sign the produced `go-mapi-setup.exe` as a separate signing request.
- **D-20:** Signing is gated on the repository secret `SIGNPATH_API_TOKEN`. The signing step uses `if: ${{ env.SIGNPATH_API_TOKEN != '' }}` on the job-level environment variable, or equivalently the GitHub Actions pattern `if: ${{ secrets.SIGNPATH_API_TOKEN != '' }}`. When the secret is missing, the two SignPath steps skip entirely and the job continues with unsigned binaries. The installer builds and the release publishes regardless.
- **D-21:** Additional required SignPath config (organization ID, project slug, signing policy slug) is stored as repository secrets: `SIGNPATH_ORG_ID`, `SIGNPATH_PROJECT_SLUG`, `SIGNPATH_SIGNING_POLICY_SLUG`. These are filled in after SignPath approval; until then, the signing steps no-op due to the token gate in D-20. The workflow file documents the required secrets inline as comments.

### Release + distribution (SIGN-04, SIGN-05)
- **D-22:** A release workflow `.github/workflows/installer-release.yml` is added. It triggers on tag push `v*`, similar to the existing `release.yml`. It runs build → signs (if gated) → builds installer → signs installer → attaches `go-mapi-setup.exe` to the GitHub Release. The existing `release.yml` is NOT modified in this phase (scope discipline); the new workflow complements it. Both workflows run on the same tag push, each producing their own release assets. The existing `release.yml` already attaches raw DLL / host / extension ZIP; the new one attaches `go-mapi-setup.exe`.
  - **Alternative considered and rejected:** merging everything into `release.yml`. Rejected because it touches Phase 4 territory and increases merge-conflict risk with parallel phases. Adding a separate workflow is strictly additive.
- **D-23:** Stable download URL: `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`. GitHub Releases serves `latest/download/<filename>` as a redirect to the latest (non-prerelease) release's asset of that filename. This URL is stable across all future releases as long as the asset name stays `go-mapi-setup.exe` (enforced by D-04).
- **D-24:** Release notes template at `.github/release-template.md`. Content includes: (a) one-line summary, (b) download link, (c) installation instructions (2-3 steps), (d) a "Windows SmartScreen guidance" subsection for the unsigned fallback case with the "More info → Run anyway" click-through steps, (e) known issues and support channel links, (f) changelog placeholder. The `softprops/action-gh-release` action in the release workflow reads this via `body_path` OR `generate_release_notes: true` combined with an `append_body` — picked in the workflow file.

### EXT-07 URL swap
- **D-25:** EXT-07 is a one-line change to `src/extension/src/popup/InstallPrompt.tsx` to replace the placeholder `INSTALLER_DOWNLOAD_URL` constant with the final URL. Because Phase 2 runs in parallel, the file may not exist in this worktree at execute time. Handling:
  - If the file exists and the placeholder URL differs from the final URL → edit in place.
  - If the file exists and the placeholder URL already matches the final URL → no-op, document as "Phase 2 pre-matched the URL per agreement."
  - If the file does not exist → skip, document as "merge-time follow-up for Phase 4 reviewer."
- **D-26:** The final URL is `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` (matches D-23 and matches what Phase 2 was told to use as placeholder — so the common case is a pre-matched no-op).

### Verification strategy
- **D-27:** Full verification requires a Windows host with `iscc.exe` (Inno Setup 6 compiler) and PowerShell 7 (`pwsh`) on PATH. If the executor has neither, verification falls back to static checks: grep for required registry paths in `.iss`, grep for required manifest path, syntax-check the Pester test file (`pwsh -NoProfile -Command "Invoke-Pester -Configuration ..."` in dry-run mode or a simple parse via `[System.Management.Automation.Language.Parser]::ParseFile`). A Windows runner in CI is the ultimate authority; `VERIFICATION.md` records which checks ran on this host and which need the CI runner to confirm.

### Claude's discretion
- Exact layout of `[Files]`, `[Registry]`, `[Code]` sections in the `.iss` script as long as the D-* decisions are honored.
- Naming of Pascal Script helper functions inside the `[Code]` section.
- Pester test Describe/Context/It naming within D-17's test list.
- Whether the smoke-test workflow uses `workflow_run` on top of `build.yml` or duplicates the build steps inline — pick whichever keeps the file shorter and easier to audit.

</decisions>

<canonical_refs>
## Canonical References

**Downstream readers must read these before planning or implementing.**

### Phase scope + requirements
- `.planning/ROADMAP.md` §"Phase 3: Inno Setup Installer + Signing + Distribution" (lines 52–63) — goal, 5 success criteria, dependency on Phase 1 FOUND-02/06, parallel with Phase 2.
- `.planning/REQUIREMENTS.md` INST-01 through INST-07 (lines 33–39), SIGN-02 through SIGN-05 (lines 44–47), EXT-07 (line 29), and the out-of-scope table at lines 105–127 for what NOT to build.
- `.planning/phases/01-foundation-signpath-application/.continue-here.md` — Phase 1 handoff; SIGN-01 filing deferred, the five decisions Phase 2/3 must honor.
- `.planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` — the application draft (reference only; not filed in Phase 3).

### Phase 1 foundations this phase consumes
- `src/native-host/manifests/com.gomapi.host.chrome.json.tmpl` and `com.gomapi.host.edge.json.tmpl` — the canonical manifest templates with `{{HOST_PATH}}` and `{{EXTENSION_ID}}` placeholders. The installer reads one of these (chrome variant) and performs literal string substitution.
- `scripts/install.ps1` — Phase 1 reference implementation of install + uninstall + template rendering + previous-client backup. The Inno Setup installer must produce the same on-disk / in-registry state as this script.
- `.planning/phases/01-foundation-signpath-application/01-06-SUMMARY.md` — manifest template design rationale.

### Build outputs this phase bundles
- `src/interceptor/build/bin/go-mapi.dll` — produced by `npm run build:interceptor` in a prior CI step.
- `src/native-host/build/go-mapi-host.exe` — produced by `npm run build:native-host` in a prior CI step.
- `package.json` `version` — source of truth for `GOMAPI_VERSION`.

### Existing workflows this phase extends
- `.github/workflows/build.yml` — existing per-PR build; Phase 3 consumes its artifacts.
- `.github/workflows/release.yml` — existing tag-triggered release; Phase 3 adds a separate `installer-release.yml`, does NOT modify this file.

### Project conventions
- `CLAUDE.md` — Windows-only, LGPL-3.0, privacy-first, no telemetry.
- User global `git-workflow.md` rule — default branch is `develop`; conventional commits (`feat`, `fix`, `docs`, `chore`, `ci`).
- User global `lockfile-discipline.md` — if any `npm install` runs, commit `package-lock.json` alongside `package.json`. Phase 3 does not touch npm.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/install.ps1` is a complete reference implementation covering prerequisites, manifest template rendering (including the JSON backslash-escape gotcha documented at lines 174–186), previous-client backup, MAPI handler registration, browser manifest registration, and uninstall. The Inno Setup script is effectively a Pascal Script translation of this PowerShell script minus the GitHub download path (the installer bundles binaries directly).
- The `.tmpl` files use double-brace placeholders (`{{HOST_PATH}}`, `{{EXTENSION_ID}}`) chosen specifically because both PowerShell `String.Replace()` and Inno Setup Pascal `StringChange` handle them trivially without regex escaping (Phase 1 FOUND-06 plan 01-06).
- `package.json` has the version field that the existing `release.yml` already reads via shell — same pattern is used by the new installer workflow.

### Established Patterns
- CI workflows use `windows-latest` runners with `pwsh` shell (PowerShell 7) by default on that runner image. Pester 5 is pre-installed on `windows-latest` per GitHub's runner docs; no install step needed for basic Pester runs.
- Build scripts read version from `package.json` and pass via `-ldflags` / CMake defines (existing `release.yml` does this inline).
- The existing `release.yml` uses `softprops/action-gh-release@v2` — the new installer workflow reuses the same action for consistency.
- Inno Setup is NOT pre-installed on `windows-latest`. The workflow installs it via Chocolatey: `choco install innosetup --no-progress -y`. After install, `iscc.exe` lives at `C:\Program Files (x86)\Inno Setup 6\iscc.exe` (Chocolatey's default path).

### Integration Points
- The installer reads from (during iscc compile): `{#SourcePath}/../native-host/build/go-mapi-host.exe` and `{#SourcePath}/../interceptor/build/bin/go-mapi.dll`. `#SourcePath` is the directory containing the `.iss` file, i.e. `src/installer/`. In CI these paths are populated by the build steps that run before `iscc.exe`.
- The installer writes to (at install time): `{app}` (= `%ProgramFiles%\go-mapi`), `HKLM\SOFTWARE\Clients\Mail\go-mapi`, five HKLM browser native-messaging registry trees, `%ProgramData%\go-mapi\com.gomapi.host.json`, `%ProgramData%\go-mapi\uninst\previous-mail-client.json`.
- The new workflow writes to: GitHub Releases assets (via `softprops/action-gh-release`), specifically a new asset `go-mapi-setup.exe` alongside the existing `release.yml` assets.

</code_context>

<specifics>
## Specific Ideas

- **Inno Setup `[Code]` section is Pascal Script, not Object Pascal.** Pascal Script has no `Result :=` in a procedure, only in a function; supports `StringChange`, `LoadStringFromFile`, `SaveStringToFile`, `RegQueryStringValue`, `RegWriteStringValue`, `ForceDirectories`, `DeleteFile`, `DelTree`. That's all we need. Don't reach for `uses SysUtils` — Inno Setup's built-in functions cover every operation listed in the decisions.
- **`StringChange` signature** is `StringChange(var S: String; const FromStr, ToStr: String): Integer` — mutates its first argument and returns the count of replacements. The Pascal rendering helper reads the template file into a string, calls `StringChange` twice (once per placeholder), writes the string out.
- **JSON escape for Windows paths:** the `{app}\go-mapi-host.exe` path must have backslashes doubled before being inserted into the JSON `path` field. Pascal code: `StringChange(HostPath, '\', '\\');` before `StringChange(Template, '{{HOST_PATH}}', HostPath);`. Matches the PowerShell approach at `install.ps1:180`.
- **Previous-client backup file format is JSON**, not plain text. `install.ps1` stores `.previous-mail-client` as plain text for historical reasons; the INST-05 requirement explicitly says "JSON" and names the file `previous-mail-client.json`. We follow the requirement, not the legacy format. Uninstaller reads the JSON and extracts `.previousClient`.
- **SignPath action parameters** for `SignPath/github-action-submit-signing-request@v1` need (per public docs): `api-token`, `organization-id`, `project-slug`, `signing-policy-slug`, `artifact-configuration-slug`, `github-artifact-id` (or `input-artifact-path` depending on version), `wait-for-completion: true`, `output-artifact-directory`. We document the required secrets inline. Until the secrets exist, the steps skip via the `if:` gate on `SIGNPATH_API_TOKEN`.
- **Pester 5 on `windows-latest`** uses `Invoke-Pester -Configuration @{ Run = @{ Path = 'installer.Tests.ps1'; Exit = $true }; Output = @{ Verbosity = 'Detailed' } }`. The older `Invoke-Pester script.ps1 -EnableExit` syntax is Pester 4 and should not be used.
- **Silent install switches for Inno Setup:** `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=path`. The uninstaller's own switches match: `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`.
- **The browser registry tree for Vivaldi** uses `HKLM\SOFTWARE\Vivaldi\NativeMessagingHosts\com.gomapi.host`. Vivaldi specifically supports the same native-messaging registry scheme as Chromium, with its own vendor key. Brave uses `HKLM\SOFTWARE\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.gomapi.host`. These paths are documented in each browser's native-messaging docs.

</specifics>

<deferred>
## Deferred Ideas

- **Actually filing the SignPath application** — Phase 1 deferred, Marc's call. Phase 3 signing pipeline works with the secrets absent; when Marc files and gets approval, he adds `SIGNPATH_API_TOKEN` + the other three secrets and the pipeline starts signing without any code change.
- **Publishing a real GitHub Release** — release workflow is tag-triggered; no tag is pushed as part of this phase. Marc pushes the `v2.0.0` tag when ready and the workflow runs.
- **blegal.dev mirror URL (DIST-01)** — v2 requirement, deferred. The v2.0.0 extension links directly to the GitHub Releases URL.
- **Edge Add-ons Store publication (DIST-02)** — v2 requirement, deferred.
- **Host self-update (UPDATE-01/02)** — v2 requirement, deferred.
- **Cleaning `%TEMP%\go-mapi\` for all user profiles on uninstall** — out of scope; only the installer-visible `%TEMP%` is cleaned. Real runtime files are already deleted on processing per the native host's privacy-first model.
- **Cross-signing on Authenticode timestamp authority** — SignPath handles this; no extra config needed.
- **Installer localization / multi-language** — out of roadmap, English-only for v2.0.0 per user's i18n rule for external projects.

</deferred>

---

*Phase: 03-inno-setup-installer-signing-distribution*
*Context gathered: 2026-04-10 (executor-derived from ROADMAP + REQUIREMENTS + Phase 1 handoff)*
