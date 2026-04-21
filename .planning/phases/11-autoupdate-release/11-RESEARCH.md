# Phase 11: Autoupdate + Release - Research

**Researched:** 2026-04-21
**Domain:** Notify-only desktop update checks, release cutover, store retirement, and clean-machine release validation [VERIFIED: repo context + official docs]
**Confidence:** MEDIUM

<user_constraints>
## User Constraints (from CONTEXT.md)

Copied verbatim from `C:/dev/go-mapi/.planning/phases/11-autoupdate-release/11-CONTEXT.md` [VERIFIED: C:/dev/go-mapi/.planning/phases/11-autoupdate-release/11-CONTEXT.md]

### Locked Decisions
- **D-01:** When an update is available, show a **small persistent banner in the main window** until the user dismisses it or updates. Tray notification still exists, but the banner is the in-window anchor.
- **D-02:** The primary update affordance opens an **in-app "Update available" panel** that exposes both:
  - the GitHub release page
  - the direct stable installer URL
- **D-03:** Clicking `Download` remains **purely manual** in v3.0. The app does not offer `Quit and install`, staged installer launching, or any other helper flow until real autoupdate exists.
- **D-04:** Update-check failures are **silent** to the user. Log them, but do not surface tray/UI warnings for transient GitHub/network failures.
- **D-05:** The `Check for updates` toggle lives in the **tray context menu**, not in a dedicated settings view. Rationale: one setting does not justify a new panel yet.
- **D-06:** Users can run a **manual `Check for updates now`** action in addition to the background cadence.
- **D-07:** The app should expose **toggle + `Last checked` + `Current version`** status. Exact placement can be split between tray text, update panel, or lightweight UI, but those two status values are required.
- **D-08:** Update checks default to **enabled**, and that default should be **called out explicitly once** so the behavior is not hidden.
- **D-09:** On v3.0 GA, the Chrome Web Store and Edge Add-ons listings remain **published but frozen with strong deprecation messaging** rather than being immediately removed. The messaging should direct users to the desktop app.
- **D-10:** The main `README.md` becomes **fully v3-only**. Do not preserve v2 installation/use documentation in `docs/legacy/` or elsewhere as maintained docs. Git history is the legacy archive.
- **D-11:** Release notes use **strong cutover language**: uninstall v2, install v3, v2 is retired.
- **D-12:** Store-side delay is acceptable for phase closure as long as there is **proof that the deprecation/unpublish/freeze action was initiated** (screenshots, submitted forms, listing updates, etc.).
- **D-13:** The release smoke test may run in **Windows Sandbox or any other clean, reproducible Windows environment**. The specific host is less important than reproducibility and clean-state proof.
- **D-14:** Smoke verification should be **as automated as practical**, but a short manual tail is acceptable for shell/UI edges that are not yet worth automating.
- **D-15:** Evidence standard:
  - **Automated portions:** must include screenshots and video capture where feasible
  - **Manual portions:** require an explicit checklist
- **D-16:** The success bar for closing the phase is the **full user journey working once on a clean machine**, even if that proof is a mix of automation and manual validation.

### Claude's Discretion
- Exact copy, placement, and dismissal behavior of the persistent update banner and in-app update panel
- Whether `Last checked` is shown in the tray menu label, the update panel, the main-window banner, or a small status row, as long as it is user-visible somewhere appropriate
- How the one-time “updates are enabled by default” callout is delivered: banner, tooltip, first-run note, or onboarding text
- Exact wording used in browser-store deprecation notices, as long as it clearly redirects users to the desktop app and reflects the strong cutover stance
- Whether the smoke-test artifact bundle is produced by one script or split between installer/release verification and clean-machine flow verification

### Deferred Ideas (OUT OF SCOPE)
- Dedicated settings panel for update preferences and richer app settings
- True autoupdate flow (`Quit and install`, staged installer launch, or self-replace)
- Maintaining a polished v2 legacy documentation set inside the current docs tree
- Full end-to-end smoke-test automation with zero manual tail if that becomes worth the complexity in a later phase
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| REL-01 | Chrome/Edge extension unpublished from stores on v3.0 GA | Store dashboards support metadata updates and unpublish actions, but this conflicts with locked decision D-09 and must be resolved before planning [CITED: https://developer.chrome.com/docs/webstore/update/][CITED: https://learn.microsoft.com/en-us/microsoft-edge/extensions-chromium/publish/update] |
| REL-02 | Stable installer URL publishes `go-mapi-setup.exe` | Existing release workflow already attaches `go-mapi-setup.exe`; GitHub stable asset URL format is correct for `/releases/latest/download/...` [VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml][CITED: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases] |
| REL-03 | In-app version check uses `creativeprojects/go-selfupdate` on startup and every 24h | `go-selfupdate` is the right release-query library, but its high-level detect/update flow expects OS/arch asset naming that the current installer-only release does not satisfy [CITED: https://github.com/creativeprojects/go-selfupdate][CITED: https://pkg.go.dev/github.com/creativeprojects/go-selfupdate] |
| REL-04 | Update available notification opens browser download path only | Existing tray/main-window surfaces can host the notify-only flow; no binary replacement should be planned [VERIFIED: C:/dev/go-mapi/src/app/tray.go][VERIFIED: C:/dev/go-mapi/src/app/frontend/src/App.svelte][VERIFIED: C:/dev/go-mapi/src/app/toast.go] |
| REL-05 | User can opt out of checks | Existing flat per-user settings model is the right persistence seam for `enabled` and `last_checked` fields [VERIFIED: C:/dev/go-mapi/src/app/settings.go][VERIFIED: C:/dev/go-mapi/src/app/app.go] |
| REL-06 | Clean-machine install → sign-in → queue → draft → uninstall smoke test | Windows Sandbox supports mapped folders and startup commands; Phase 10 already covers installer round-trip, so Phase 11 should add end-to-end user-flow proof rather than rebuild installer smoke from scratch [CITED: https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file][VERIFIED: C:/dev/go-mapi/src/installer/tests/installer.Tests.ps1][VERIFIED: C:/dev/go-mapi/.github/workflows/installer-smoke.yml] |
| REL-07 | README rewritten for v3 | Current README is partially v3-only but still says Phase 9/10/11 are planned; Phase 11 must finalize it as shipped documentation [VERIFIED: C:/dev/go-mapi/README.md] |
</phase_requirements>

## Summary

Plan Phase 11 as four coordinated workstreams: backend-owned update polling, tray/window release UX, release-ops cutover, and clean-machine proof [VERIFIED: C:/dev/go-mapi/src/app/settings.go][VERIFIED: C:/dev/go-mapi/src/app/tray.go][VERIFIED: C:/dev/go-mapi/src/app/frontend/src/App.svelte][VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml]. The repo already has the release workflow, installer smoke job, toast infrastructure, tray menu loop, and flat settings file needed to implement notify-only autoupdate without adding a new subsystem [VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml][VERIFIED: C:/dev/go-mapi/.github/workflows/installer-smoke.yml][VERIFIED: C:/dev/go-mapi/src/app/toast.go][VERIFIED: C:/dev/go-mapi/src/app/app.go].

The main technical landmine is asset discovery. `creativeprojects/go-selfupdate` documents a release layout that expects assets named like `{cmd}_{goos}_{goarch}` or archived variants, and its `DetectLatest` path reports `found=false` when no matching asset exists for the running platform [CITED: https://github.com/creativeprojects/go-selfupdate]. The current release pipeline publishes a stable installer named `go-mapi-setup.exe` and nothing in the repo indicates a second `go-mapi_windows_amd64` asset is attached today [VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml]. Planning should therefore use `go-selfupdate` as the GitHub Releases client layer only and keep download as a browser handoff to the stable installer URL, rather than trying to use its self-replace path [CITED: https://pkg.go.dev/github.com/creativeprojects/go-selfupdate][CITED: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases].

**Primary recommendation:** Implement a backend update-check service that persists `enabled` and `last_checked`, queries GitHub Releases via `go-selfupdate`, emits a lightweight `update-status` model to tray/UI, opens only the release page or stable installer URL, and leaves release publication plus store retirement as explicit checklist-driven ops tasks [VERIFIED: C:/dev/go-mapi/src/app/settings.go][VERIFIED: C:/dev/go-mapi/src/app/tray.go][CITED: https://github.com/creativeprojects/go-selfupdate].

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Release check cadence, version comparison, persistence | API / Backend | Database / Storage | App startup, 24h timing, and settings persistence already live in Go under `src/app/`; this avoids duplicate timers in Svelte [VERIFIED: C:/dev/go-mapi/src/app/app.go][VERIFIED: C:/dev/go-mapi/src/app/settings.go] |
| Tray toggle + manual check action | Browser / Client | API / Backend | Menu wiring is owned by `tray.go`, but the action should call backend update-check methods that know current version and cadence state [VERIFIED: C:/dev/go-mapi/src/app/tray.go] |
| Persistent banner + update panel | Browser / Client | API / Backend | Banner/panel rendering belongs in Svelte; backing data should come from a small backend status payload [VERIFIED: C:/dev/go-mapi/src/app/frontend/src/App.svelte][VERIFIED: C:/dev/go-mapi/src/app/frontend/src/lib/settings.ts] |
| Stable installer publication | CDN / Static | API / Backend | GitHub Releases hosts the stable asset URL; the repo’s release workflow is already the publishing tier [VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml][CITED: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases] |
| Browser-store retirement messaging | API / Backend | — | This is an external dashboard/process responsibility, not app code; plan it as manual ops with evidence capture [CITED: https://developer.chrome.com/docs/webstore/update/][CITED: https://learn.microsoft.com/en-us/microsoft-edge/extensions-chromium/publish/update] |
| Clean-machine smoke verification | Browser / Client | API / Backend | The proof path crosses installer, OAuth, queue, tray/toast, and uninstall, so it needs an environment harness plus app/backend assertions [CITED: https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file][VERIFIED: C:/dev/go-mapi/src/installer/tests/installer.Tests.ps1] |

## Project Constraints (from CLAUDE.md)

- Windows 10/11 only; do not plan cross-platform update mechanics [VERIFIED: C:/dev/go-mapi/CLAUDE.md]
- Distribution stays a single-file NSIS installer on GitHub Releases; WebView2 is installer-bootstrapped [VERIFIED: C:/dev/go-mapi/CLAUDE.md]
- No telemetry; no content retention; only Gmail API plus GitHub Releases update checks are allowed network calls [VERIFIED: C:/dev/go-mapi/CLAUDE.md]
- Keep the two-component stack intact: C++ DLL plus Wails desktop app; Phase 11 must not resurrect extension-era architecture [VERIFIED: C:/dev/go-mapi/CLAUDE.md]
- Version authority already lives in `src/app/wails.json`; planning must not introduce a second version source [VERIFIED: C:/dev/go-mapi/src/app/wails.json][VERIFIED: C:/dev/go-mapi/.planning/phases/10-installer-migration/10-06-SUMMARY.md]

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `github.com/creativeprojects/go-selfupdate` | `v1.5.2` (tag dated 2025-12-19) | Query GitHub Releases and compare versions without hand-rolling release parsing [CITED: https://github.com/creativeprojects/go-selfupdate/tags][CITED: https://pkg.go.dev/github.com/creativeprojects/go-selfupdate] | It already provides GitHub source, version comparison helpers, and update-oriented release metadata primitives [CITED: https://pkg.go.dev/github.com/creativeprojects/go-selfupdate] |
| Wails backend + existing app bindings | `v2.12.0` | Own update cadence, settings persistence, tray actions, and event emission [VERIFIED: C:/dev/go-mapi/src/app/app.go][VERIFIED: C:/dev/go-mapi/src/app/tray.go][VERIFIED: C:/dev/go-mapi/src/app/wails.json] | The repo already centralizes long-lived app state in Go, not in the frontend [VERIFIED: C:/dev/go-mapi/src/app/app.go] |
| Windows Sandbox (`.wsb`) | Windows built-in feature | Reproducible clean-machine smoke execution with mapped host folders and startup command [CITED: https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file] | It is the lightest reproducible clean-room option already available on this machine [VERIFIED: local shell `WindowsSandbox` command present] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| GitHub Releases stable asset URLs | Current platform behavior | Stable public download URL for `go-mapi-setup.exe` [CITED: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases] | Use for the panel’s direct installer link and post-release verification |
| Existing installer-release workflow | Repo current | Tag-driven installer publication and version gate [VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml] | Use for REL-02 cutover; do not replace it |
| Existing installer smoke workflow + Pester suite | Repo current | Install/uninstall regression gate [VERIFIED: C:/dev/go-mapi/.github/workflows/installer-smoke.yml][VERIFIED: C:/dev/go-mapi/src/installer/tests/installer.Tests.ps1] | Reuse as prerequisite proof before end-to-end sandbox flow |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `go-selfupdate` release querying | Hand-rolled GitHub REST client | More control over installer-only assets, but it duplicates version parsing and ignores the locked library choice [CITED: https://docs.github.com/en/rest/releases/releases][VERIFIED: C:/dev/go-mapi/.planning/STATE.md] |
| Windows Sandbox | Full VM/manual clean machine | Equivalent proof is possible, but Windows Sandbox is easier to script and reproduce for this repo [CITED: https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file] |

**Installation:**
```bash
go get github.com/creativeprojects/go-selfupdate@v1.5.2
```

**Version verification:** `go list -m -versions` could not be used in-session because outbound module proxy access is blocked in this sandbox; the version above was verified from the upstream tags page and pkg.go.dev instead [VERIFIED: local shell error + web sources].

## Architecture Patterns

### System Architecture Diagram
```text
App start / tray manual action
    |
    v
Go update service (src/app/) ------------------------------+
    |                                                      |
    | loads persisted prefs + last_checked                 |
    | [settings.json]                                      |
    v                                                      |
24h gate / startup gate / manual bypass                    |
    |                                                      |
    v                                                      |
GitHub Releases query via go-selfupdate -------------------+--> compare with current version from wails.json/build ldflags
    |
    +--> no newer stable release -> update last_checked, emit idle status
    |
    +--> newer stable release -> emit update-status event/state
                                      |
                                      +--> tray notification + tray menu labels
                                      |
                                      +--> App.svelte banner + update panel
                                                  |
                                                  +--> open release page
                                                  +--> open stable installer URL

Release ops:
wails.json version bump -> tag push -> installer-release.yml -> GitHub Release asset -> latest/download URL

Verification:
installer-smoke.yml pass -> Windows Sandbox script -> install -> sign in -> send test mail -> create Gmail draft -> uninstall -> capture evidence
```

### Recommended Project Structure
```text
src/app/
├── updatecheck.go          # release query, 24h gating, status model, manual check entrypoint
├── settings.go             # extend AppSettings with update fields
├── tray.go                 # add toggle + manual check item + status text
├── app.go                  # expose Wails bindings/events for update status
└── frontend/src/
    ├── lib/components/UpdateBanner.svelte
    ├── lib/components/UpdatePanel.svelte
    └── App.svelte          # mount banner/panel in existing shell

scripts/sandbox/
├── phase11-smoke.wsb       # mapped folder + logon command
└── run-phase11-smoke.ps1   # orchestrates install/sign-in/MAPI/uninstall evidence
```

### Pattern 1: Backend-Owned Release Poller
**What:** Put startup checks, 24h cadence, version comparison, and persisted `last_checked` in Go, then surface a small immutable status model to tray/UI [VERIFIED: C:/dev/go-mapi/src/app/app.go][VERIFIED: C:/dev/go-mapi/src/app/settings.go].
**When to use:** Every startup, background cadence tick, and tray-triggered manual check [VERIFIED: C:/dev/go-mapi/.planning/phases/11-autoupdate-release/11-CONTEXT.md].
**Example:**
```go
// Source: https://github.com/creativeprojects/go-selfupdate
repository := selfupdate.ParseSlug("marcfargas/go-mapi")
latest, found, err := selfupdate.DetectLatest(context.Background(), repository)
if err != nil {
    return err
}
if !found {
    return nil
}
if latest.LessOrEqual(currentVersion) {
    return nil
}
```
**Planning note:** Use this exact path only if the release also ships a matching `go-selfupdate` platform asset; the current installer-only asset name does not satisfy the documented naming rule [CITED: https://github.com/creativeprojects/go-selfupdate][VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml].

### Pattern 2: Extend the Existing Flat Settings Model
**What:** Add update fields to `AppSettings` and reuse the existing atomic per-user write path [VERIFIED: C:/dev/go-mapi/src/app/settings.go].
**When to use:** Persist `update_checks_enabled`, `last_update_check_at`, and any one-time callout acknowledgement [VERIFIED: C:/dev/go-mapi/.planning/phases/11-autoupdate-release/11-CONTEXT.md].
**Example:**
```go
// Source: C:/dev/go-mapi/src/app/settings.go
type AppSettings struct {
    Mode string `json:"mode"`
}
```

### Pattern 3: Sandbox-Driven End-to-End Smoke Harness
**What:** Launch a reproducible Windows Sandbox instance from a checked-in `.wsb`, map a host evidence folder, and auto-run a PowerShell harness [CITED: https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file].
**When to use:** Final release proof, not everyday CI [CITED: https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file].
**Example:**
```xml
<!-- Source: https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file -->
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>C:\path\to\phase11-artifacts</HostFolder>
      <SandboxFolder>C:\Artifacts</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -ExecutionPolicy Bypass -File C:\Artifacts\run-phase11-smoke.ps1</Command>
  </LogonCommand>
</Configuration>
```

### Anti-Patterns to Avoid
- **Using `UpdateSelf` / in-process replacement:** This directly contradicts project scope and Phase 11 decisions [VERIFIED: C:/dev/go-mapi/.planning/REQUIREMENTS.md][VERIFIED: C:/dev/go-mapi/.planning/phases/11-autoupdate-release/11-CONTEXT.md].
- **Running release checks in Svelte:** The frontend should render state, not own timers, persistence, or version parsing [VERIFIED: C:/dev/go-mapi/src/app/app.go][VERIFIED: C:/dev/go-mapi/src/app/frontend/src/App.svelte].
- **Showing transient GitHub failures to users:** Locked decision D-04 says log-only [VERIFIED: C:/dev/go-mapi/.planning/phases/11-autoupdate-release/11-CONTEXT.md].
- **Treating browser-store retirement as code-only work:** Store actions live outside git and need explicit proof capture [CITED: https://developer.chrome.com/docs/webstore/update/][CITED: https://learn.microsoft.com/en-us/microsoft-edge/extensions-chromium/publish/update].

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| GitHub release version parsing | Custom semver + HTTP client stack | `creativeprojects/go-selfupdate` release/source primitives | The library already models releases, repositories, version comparison, and update-oriented flows [CITED: https://pkg.go.dev/github.com/creativeprojects/go-selfupdate] |
| Stable download URL resolution | Custom redirect service | GitHub `/releases/latest/download/<asset>` URL | GitHub documents this URL shape explicitly [CITED: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases] |
| Per-user settings persistence | Second config file or registry store | Existing `%APPDATA%\\go-mapi\\settings.json` path | The repo already has atomic writes and validation in place [VERIFIED: C:/dev/go-mapi/src/app/settings.go] |
| Clean-room Windows environment | Ad-hoc manual workstation prep | Windows Sandbox `.wsb` + mapped artifact folder | Microsoft documents folder mapping and startup commands, which fit the required evidence flow [CITED: https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file] |

**Key insight:** The only part worth adding is a thin release-check layer; almost every other concern in Phase 11 is extension of existing repo infrastructure, not a new subsystem [VERIFIED: repo files cited above].

## Common Pitfalls

### Pitfall 1: `go-selfupdate` Never Finds the Release
**What goes wrong:** Startup checks always report no update even after tagging a newer release [CITED: https://github.com/creativeprojects/go-selfupdate].
**Why it happens:** The documented asset matcher expects platform-specific binary asset names, while this repo publishes only `go-mapi-setup.exe` [CITED: https://github.com/creativeprojects/go-selfupdate][VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml].
**How to avoid:** Use `go-selfupdate` only as the GitHub Releases client layer for metadata, or publish a second matching Windows asset specifically for detection [CITED: https://pkg.go.dev/github.com/creativeprojects/go-selfupdate].
**Warning signs:** `found=false` on a release that clearly exists in GitHub UI [CITED: https://github.com/creativeprojects/go-selfupdate].

### Pitfall 2: Tag Push Fails Release Day
**What goes wrong:** The release workflow aborts before publishing the installer [VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml].
**Why it happens:** The workflow validates the pushed tag against `src/app/wails.json` `info.productVersion`, and the repo intentionally still has placeholder `0.0.0` [VERIFIED: C:/dev/go-mapi/src/app/wails.json][VERIFIED: C:/dev/go-mapi/.planning/phases/10-installer-migration/10-06-SUMMARY.md].
**How to avoid:** Make “bump `wails.json` to `3.0.0`” the first release-cutover task and verify `workflow_dispatch` dry run before the real tag [VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml].
**Warning signs:** Version mismatch exception in the workflow logs [VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml].

### Pitfall 3: Wrong Release Type Breaks Stable URLs and Checks
**What goes wrong:** The app or the stable URL points at the wrong release [CITED: https://docs.github.com/en/rest/releases/releases][CITED: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases].
**Why it happens:** GitHub’s “latest release” semantics use the latest published non-draft, non-prerelease release [CITED: https://docs.github.com/en/rest/releases/releases].
**How to avoid:** Publish `v3.0.0` as a full release, not prerelease, and verify the `latest/download` URL after publish [CITED: https://docs.github.com/en/rest/releases/releases][CITED: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases].
**Warning signs:** Release page exists but `/releases/latest/download/go-mapi-setup.exe` still resolves to an older tag [CITED: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases].

### Pitfall 4: Banner and Tray State Drift
**What goes wrong:** Users see contradictory `Current version` / `Last checked` / update-available states between tray and window [VERIFIED: C:/dev/go-mapi/src/app/tray.go][VERIFIED: C:/dev/go-mapi/src/app/frontend/src/App.svelte].
**Why it happens:** State is computed in two places or manual check bypasses persisted timestamps [VERIFIED: C:/dev/go-mapi/src/app/app.go][VERIFIED: C:/dev/go-mapi/src/app/settings.go].
**How to avoid:** Keep one backend `update-status` model and have tray + UI render it [VERIFIED: existing backend-owned state patterns in C:/dev/go-mapi/src/app/app.go].
**Warning signs:** Manual check updates only one surface or `last checked` changes without settings write [VERIFIED: C:/dev/go-mapi/src/app/settings.go].

### Pitfall 5: Store Retirement “Done” Has No Evidence
**What goes wrong:** The phase claims REL-01 closed but no one can prove which dashboard action was taken [VERIFIED: phase decision D-12 in C:/dev/go-mapi/.planning/phases/11-autoupdate-release/11-CONTEXT.md].
**Why it happens:** Store dashboards are external to git and often have review delays [CITED: https://developer.chrome.com/docs/webstore/update/][CITED: https://learn.microsoft.com/en-us/microsoft-edge/extensions-chromium/publish/update].
**How to avoid:** Treat screenshots/forms/listing text as required deliverables in the plan [VERIFIED: phase decision D-12 in C:/dev/go-mapi/.planning/phases/11-autoupdate-release/11-CONTEXT.md].
**Warning signs:** Only README/release-note changes exist, but no store proof exists [VERIFIED: repo-only evidence cannot prove dashboard changes].

## Code Examples

Verified patterns from official sources:

### Notify-Only Release Detection
```go
// Source: https://github.com/creativeprojects/go-selfupdate
repository := selfupdate.ParseSlug("marcfargas/go-mapi")
latest, found, err := selfupdate.DetectLatest(context.Background(), repository)
if err != nil {
    log.Printf("Error occurred while detecting version: %v", err)
    return
}
if !found {
    return
}
fmt.Println("latest version:", latest.Version())
```

### Stable GitHub Release Download Link
```text
https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe
```
Source: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases

### Windows Sandbox Startup Automation
```xml
<!-- Source: https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file -->
<LogonCommand>
  <Command>powershell.exe -ExecutionPolicy Bypass -File C:\Artifacts\run-phase11-smoke.ps1</Command>
</LogonCommand>
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Browser extension + native host delivery | Desktop installer release via GitHub Releases | v3 milestone decision already locked in project docs [VERIFIED: C:/dev/go-mapi/CLAUDE.md][VERIFIED: C:/dev/go-mapi/README.md] | Phase 11 should finish cutover, not preserve dual-track docs |
| In-process self-update | Notify-only check + browser-open installer handoff | v3 requirements/out-of-scope already reject binary self-replace [VERIFIED: C:/dev/go-mapi/.planning/REQUIREMENTS.md] | Planner should not allocate work to installer launching or exe replacement |
| Version source spread across docs/build scripts | `src/app/wails.json` as release authority | Phase 10 locked this in [VERIFIED: C:/dev/go-mapi/src/app/wails.json][VERIFIED: C:/dev/go-mapi/.planning/phases/10-installer-migration/10-06-SUMMARY.md] | Release-day tasks must start with a version bump there |

**Deprecated/outdated:**
- v2.x browser-store-first distribution flow is obsolete for v3 release planning [VERIFIED: C:/dev/go-mapi/README.md][VERIFIED: C:/dev/go-mapi/.github/release-template.md].

## Assumptions Log

All nontrivial technical claims in this research were verified from repo state or official docs. No training-only assumptions were used.

## Open Questions (RESOLVED)

1. **REL-01 vs D-09 / D-12**
   - Resolution: for Phase 11, REL-01 is interpreted as **retire the store listings via frozen/deprecated pages with strong desktop-app cutover messaging plus captured proof**, not hard immediate unpublish.
   - Action taken: planning artifacts should align the requirements/roadmap text to that locked decision so execution and verification are not contradictory.

2. **`go-selfupdate` with installer-only release assets**
   - Resolution: Phase 11 uses a **metadata-only query path** with `creativeprojects/go-selfupdate`.
   - Concrete choice: do **not** use the library’s asset-matching `DetectLatest` flow as the primary detection path for this release layout. Use its GitHub release/source/version primitives only, compare against the current app version, and open the release page or stable installer URL manually.
   - Deferred: adding a second platform-matching asset is explicitly out of scope for Phase 11.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Go | updater implementation, local release utilities | ✓ | `go1.26.1` [VERIFIED: local shell `go version`] | CI still pins Go 1.25 for official builds [VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml] |
| Node.js | frontend banner/panel work | ✓ | `v24.13.0` [VERIFIED: local shell] | — |
| npm | frontend build/test | ✓ | `11.6.2` [VERIFIED: local shell] | — |
| Wails CLI | local desktop build | ✓ | `v2.12.0` [VERIFIED: local shell `wails version`] | CI installs it explicitly [VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml] |
| Windows Sandbox | clean-machine smoke | ✓ | built-in feature [VERIFIED: local shell command present] | Alternative clean VM if Sandbox is disabled on another machine [CITED: https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file] |
| NSIS (`makensis`) | local installer rehearsal | ✗ | — [VERIFIED: local shell] | CI installs or validates NSIS automatically [VERIFIED: C:/dev/go-mapi/.github/workflows/installer-release.yml][VERIFIED: C:/dev/go-mapi/.github/workflows/installer-smoke.yml] |
| Pester / PowerShell | installer smoke and sandbox scripts | ✓ | `pwsh 7.5.4` locally [VERIFIED: local shell] | GitHub runner already uses PowerShell in existing workflows [VERIFIED: C:/dev/go-mapi/.github/workflows/installer-smoke.yml] |

**Missing dependencies with no fallback:**
- None identified for planning.

**Missing dependencies with fallback:**
- Local `makensis` is missing, but both existing workflows install or validate NSIS in CI, so local release rehearsal is optional rather than blocking [VERIFIED: workflow files].

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | Phase 11 does not add new user auth flows; it reuses existing Google auth only during smoke validation [VERIFIED: C:/dev/go-mapi/.planning/REQUIREMENTS.md] |
| V3 Session Management | no | No new session model is introduced by update checks [VERIFIED: phase scope] |
| V4 Access Control | no | No multi-user authorization layer is added in this phase [VERIFIED: phase scope] |
| V5 Input Validation | yes | Validate GitHub release metadata, version strings, tray actions, and settings fields using existing backend-owned validation patterns [VERIFIED: C:/dev/go-mapi/src/app/app.go][VERIFIED: C:/dev/go-mapi/src/app/settings.go] |
| V6 Cryptography | no | Notify-only flow does not download or execute binaries inside the app; if that changes later, use library-provided checksum/signature validation rather than custom crypto [CITED: https://pkg.go.dev/github.com/creativeprojects/go-selfupdate] |

### Known Threat Patterns for this Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Draft/prerelease confusion causes wrong release to appear “latest” | Tampering | Query only published stable releases and verify the final stable URL after release [CITED: https://docs.github.com/en/rest/releases/releases][CITED: https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases] |
| Hardcoded or user-controlled external URLs drift away from the repo | Tampering | Keep repo slug, release page URL, and stable installer URL hardcoded to `marcfargas/go-mapi` in backend code [VERIFIED: project/repo naming] |
| Corrupt settings disable checks or break cadence | Denial of Service | Reuse the existing fail-safe settings loader and default enabled state mandated by D-08 [VERIFIED: C:/dev/go-mapi/src/app/settings.go][VERIFIED: C:/dev/go-mapi/.planning/phases/11-autoupdate-release/11-CONTEXT.md] |
| Notification spam on repeated failures | Denial of Service | Persist `last_checked`, honor 24h cadence, separate manual checks, and keep transient failures silent [VERIFIED: requirements + locked decisions] |

## Sources

### Primary (HIGH confidence)
- `C:/dev/go-mapi/.planning/phases/11-autoupdate-release/11-CONTEXT.md` - locked decisions, discretion, and deferred scope
- `C:/dev/go-mapi/.planning/REQUIREMENTS.md` - REL-01..REL-07
- `C:/dev/go-mapi/.planning/STATE.md` - locked updater choice and phase handoff state
- `C:/dev/go-mapi/CLAUDE.md` - project constraints
- `C:/dev/go-mapi/.github/workflows/installer-release.yml` - current release pipeline
- `C:/dev/go-mapi/.github/workflows/installer-smoke.yml` - current installer smoke gate
- `C:/dev/go-mapi/src/app/settings.go` - settings model and atomic write pattern
- `C:/dev/go-mapi/src/app/app.go` - backend-owned state/event pattern
- `C:/dev/go-mapi/src/app/tray.go` - tray menu/state integration points
- `C:/dev/go-mapi/src/app/frontend/src/App.svelte` - existing signed-in shell anchor
- `https://github.com/creativeprojects/go-selfupdate` - release asset naming contract and detect/update examples
- `https://pkg.go.dev/github.com/creativeprojects/go-selfupdate` - exported API surface
- `https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases` - stable release URLs
- `https://docs.github.com/en/rest/releases/releases` - latest-release semantics
- `https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file` - Windows Sandbox `.wsb` config, mapped folders, startup commands

### Secondary (MEDIUM confidence)
- `https://developer.chrome.com/docs/webstore/update/` - Chrome Web Store item metadata/update controls
- `https://developer.chrome.com/docs/webstore/cws-dashboard-distribution/` - Chrome visibility/distribution options
- `https://learn.microsoft.com/en-us/microsoft-edge/extensions-chromium/publish/update` - Edge Add-ons metadata updates and publish flow
- `https://learn.microsoft.com/en-us/microsoft-edge/extensions-chromium/publish/publish-extension` - Edge Add-ons publish/unpublish control availability

### Tertiary (LOW confidence)
- None.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - repo and official docs are clear, and the plan now locks a metadata-only `go-selfupdate` integration path because the installer asset name does not match the library’s documented detect flow
- Architecture: HIGH - repo extension points and release workflow are already present
- Pitfalls: HIGH - the major risks are directly visible in official docs or current repo state

**Research date:** 2026-04-21
**Valid until:** 2026-05-21
