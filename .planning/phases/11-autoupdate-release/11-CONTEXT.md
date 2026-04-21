# Phase 11: Autoupdate + Release - Context

**Gathered:** 2026-04-21
**Status:** Ready for planning

<domain>
## Phase Boundary

Ship the v3.0 release surface on top of the completed Wails app and installer work:

1. **Notify-only update checks** using GitHub Releases as the source of truth. The app checks on startup and on the 24h cadence already implied by requirements, surfaces an available update through tray/UI affordances, and never performs in-process binary replacement.
2. **Release distribution** through the stable installer URL `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`, using the existing Phase 10 release workflow and `wails.json` version authority.
3. **Update preferences** so users can disable background update checks and manually trigger an on-demand check.
4. **v2.x retirement messaging and store wind-down** for the old Chrome/Edge extension listings, with strong migration language toward the desktop app.
5. **Clean-machine smoke verification** for the full v3.0 path: install → sign in → MAPI trigger → queued email → Gmail draft → uninstall clean.

Covers requirements: REL-01, REL-02, REL-03, REL-04, REL-05, REL-06, REL-07.

**Out of scope for Phase 11:**
- In-process self-update, background binary replacement, or auto-install after download
- A dedicated settings screen/view just for update preferences
- Maintaining v2.x legacy documentation in the main docs tree
- A hard requirement that browser store deprecation/unpublish requests be fully processed by the stores before the phase can close

</domain>

<decisions>
## Implementation Decisions

### Update UX
- **D-01:** When an update is available, show a **small persistent banner in the main window** until the user dismisses it or updates. Tray notification still exists, but the banner is the in-window anchor.
- **D-02:** The primary update affordance opens an **in-app "Update available" panel** that exposes both:
  - the GitHub release page
  - the direct stable installer URL
- **D-03:** Clicking `Download` remains **purely manual** in v3.0. The app does not offer `Quit and install`, staged installer launching, or any other helper flow until real autoupdate exists.
- **D-04:** Update-check failures are **silent** to the user. Log them, but do not surface tray/UI warnings for transient GitHub/network failures.

### Update Preference Surface
- **D-05:** The `Check for updates` toggle lives in the **tray context menu**, not in a dedicated settings view. Rationale: one setting does not justify a new panel yet.
- **D-06:** Users can run a **manual `Check for updates now`** action in addition to the background cadence.
- **D-07:** The app should expose **toggle + `Last checked` + `Current version`** status. Exact placement can be split between tray text, update panel, or lightweight UI, but those two status values are required.
- **D-08:** Update checks default to **enabled**, and that default should be **called out explicitly once** so the behavior is not hidden.

### Release + Store Retirement
- **D-09:** On v3.0 GA, the Chrome Web Store and Edge Add-ons listings remain **published but frozen with strong deprecation messaging** rather than being immediately removed. The messaging should direct users to the desktop app.
- **D-10:** The main `README.md` becomes **fully v3-only**. Do not preserve v2 installation/use documentation in `docs/legacy/` or elsewhere as maintained docs. Git history is the legacy archive.
- **D-11:** Release notes use **strong cutover language**: uninstall v2, install v3, v2 is retired.
- **D-12:** Store-side delay is acceptable for phase closure as long as there is **proof that the deprecation/unpublish/freeze action was initiated** (screenshots, submitted forms, listing updates, etc.).

### Smoke-Test Standard
- **D-13:** The release smoke test may run in **Windows Sandbox or any other clean, reproducible Windows environment**. The specific host is less important than reproducibility and clean-state proof.
- **D-14:** Smoke verification should be **as automated as practical**, but a short manual tail is acceptable for shell/UI edges that are not yet worth automating.
- **D-15:** Evidence standard:
  - **Automated portions:** must include screenshots and video capture where feasible
  - **Manual portions:** require an explicit checklist
- **D-16:** The success bar for closing the phase is the **full user journey working once on a clean machine**, even if that proof is a mix of automation and manual validation.

### the agent's Discretion
- Exact copy, placement, and dismissal behavior of the persistent update banner and in-app update panel
- Whether `Last checked` is shown in the tray menu label, the update panel, the main-window banner, or a small status row, as long as it is user-visible somewhere appropriate
- How the one-time “updates are enabled by default” callout is delivered: banner, tooltip, first-run note, or onboarding text
- Exact wording used in browser-store deprecation notices, as long as it clearly redirects users to the desktop app and reflects the strong cutover stance
- Whether the smoke-test artifact bundle is produced by one script or split between installer/release verification and clean-machine flow verification

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope and requirements
- `.planning/ROADMAP.md` §Phase 11: Autoupdate + Release — goal and the 5 success criteria that define the phase boundary
- `.planning/REQUIREMENTS.md` §Release & Autoupdate — REL-01 through REL-07
- `.planning/PROJECT.md` — v3.0 milestone goal, privacy baseline, clean-break migration, and the explicit rejection of in-process self-update
- `.planning/STATE.md` — carried-forward decision that autoupdate is notify-only via `creativeprojects/go-selfupdate`

### Upstream phase context
- `.planning/phases/09-queue-automode-toasts/09-CONTEXT.md` — tray/toast behavior, AUMID assumptions, existing notification patterns, and the sandbox-automation handoff
- `.planning/phases/10-installer-migration/10-CONTEXT.md` — stable installer URL, release workflow shape, `wails.json` version authority, release-template direction, and installer smoke-test conventions
- `.planning/phases/10-installer-migration/10-06-SUMMARY.md` — concrete release-pipeline outcome, dry-run behavior, and release-template rewrite already landed

### Research and automation context
- `.planning/research/ARCHITECTURE.md` §7 Autoupdate Architecture — notify-only update strategy, `go-selfupdate`, and GitHub Releases cadence assumptions
- `.planning/todos/pending/2026-04-19-automate-tray-visual-qa-windows-sandbox.md` — Windows Sandbox + automation direction that informs Phase 11 smoke-test expectations

### Existing code and release surface
- `.github/workflows/installer-release.yml` — current release pipeline, stable asset attachment behavior, and dry-run artifact path
- `.github/release-template.md` — current v3 release-note baseline
- `src/app/settings.go` — persisted settings shape and atomic save pattern
- `src/app/frontend/src/lib/settings.ts` — existing settings bindings surface
- `src/app/tray.go` — tray/menu integration point for the new update toggle and manual check action
- `src/app/frontend/src/App.svelte` — current main-window shell where the persistent update banner/panel will integrate
- `src/app/wails.json` — `info.productVersion` source of truth
- `README.md` — current v3-facing install/deprecation language that Phase 11 will finalize

### External references
- `https://github.com/creativeprojects/go-selfupdate` — updater library already chosen for notify-only checks
- `https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases` — GitHub Releases semantics relevant to stable asset delivery

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`src/app/settings.go`** already persists flat per-user settings safely with an atomic write pattern. Phase 11 should extend `AppSettings` rather than invent a second config file.
- **`src/app/frontend/src/lib/settings.ts`** already exposes settings bindings and tray-related pause/mode primitives. Phase 11 can follow the same wrapper style for update preferences and manual update checks.
- **`src/app/tray.go`** already owns the tray menu lifecycle and state refresh model. The update toggle and `Check for updates now` action belong here.
- **`src/app/frontend/src/App.svelte`** already has the signed-in shell and banner/header patterns needed for a lightweight persistent update banner without inventing a new view architecture.
- **`.github/workflows/installer-release.yml`** already ships the installer artifact through the correct release path. Phase 11 should build on it rather than replacing it.

### Established Patterns
- Settings are per-user, flat, and stored in `%APPDATA%\go-mapi\settings.json`.
- Tray state/menu actions are treated as first-class UX, not a fallback.
- Version authority is already centralized in `src/app/wails.json`.
- Release automation prefers additive, explicit workflows with dry-run support.
- The project consistently favors pragmatic release mechanics over heavy infrastructure: manual install is acceptable; notify-only update flow is an intentional scope choice.

### Integration Points
- **Backend updater logic:** new update-check code should live under `src/app/` and integrate with the existing tray and settings model.
- **Tray menu:** add update toggle + `Check for updates now` here.
- **Main-window UX:** mount persistent update banner/panel in `App.svelte` or an adjacent component, without creating a full settings screen.
- **Release notes / README:** Phase 11 needs coordinated changes across `.github/release-template.md` and `README.md` to finalize the v3-only cutover.
- **Smoke verification:** likely extends the installer/release workflow plus a clean-machine validation script/artifact bundle, with Windows Sandbox or equivalent as the execution target.

</code_context>

<specifics>
## Specific Ideas

- The update banner should remain small and durable, not modal or noisy.
- The in-app update panel should present both:
  - the human-readable release page
  - the direct `go-mapi-setup.exe` stable link
- The current pragmatic preference is: **tray menu now, fuller settings panel later**.
- Legacy docs should not be maintained in-tree; if someone needs v2, they can use git history/tags.
- Automation evidence should be richer than text alone when automation is involved: screenshots and video are preferred, not just logs.

</specifics>

<deferred>
## Deferred Ideas

- Dedicated settings panel for update preferences and richer app settings
- True autoupdate flow (`Quit and install`, staged installer launch, or self-replace)
- Maintaining a polished v2 legacy documentation set inside the current docs tree
- Full end-to-end smoke-test automation with zero manual tail if that becomes worth the complexity in a later phase

</deferred>

---

*Phase: 11-autoupdate-release*
*Context gathered: 2026-04-21*
