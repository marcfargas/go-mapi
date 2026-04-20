---
phase: 10-installer-migration
plan: 06
subsystem: infra
tags: [installer, release, signpath, github-actions, ci, wails-config, ldflags, nsis]

# Dependency graph
requires:
  - phase: 10-installer-migration
    provides: "NSIS installer source (src/installer/go-mapi.nsi, plan 10-01); AUMID var + toast tests (plan 10-03); SignPath v2 action pattern documented (plan 10-CONTEXT D-23/D-24 + PATTERNS.md errata)"
  - phase: 08-oauth-credentials
    provides: "ldflags-injected main.oauthClientID / main.oauthClientSecret pattern; GOMAPI_OAUTH_CLIENT_ID / GOMAPI_OAUTH_CLIENT_SECRET repo secrets"
  - phase: 09-queue-ui
    provides: "main.aumidOverride ldflags seam (WR-01) for toast persistence"
provides:
  - "Tag-triggered signed release pipeline: push v* → build → SignPath pass 1 → makensis → SignPath pass 2 → GH Release attach"
  - "wails.json info.productVersion as version authority (D-26); validated against pushed tag before any signing"
  - "SignPath graceful-skip fallback when SIGNPATH_API_TOKEN is absent (D-24) — unsigned pipeline still publishes"
  - "Static v3.0 release-notes scaffold with v2.x uninstall warning (mirrors plan 10-04 README) consumed by softprops/action-gh-release@v2 body_path"
  - "workflow_dispatch dry_run path: uploads the final installer as an artifact instead of publishing, safe to exercise pre-tag"
affects: [11-release, REL-02, phase-11-v3.0-tag-push]

# Tech tracking
tech-stack:
  added:
    - "signpath/github-action-submit-signing-request@v2 (code signing action — v2 per PATTERNS.md §Planner-Facing Correction Log, NOT v1 from CONTEXT D-23)"
    - "softprops/action-gh-release@v2 (GitHub Release asset publish)"
    - "actions/upload-artifact@v4 (SignPath input + workflow_dispatch dry-run artifact)"
  patterns:
    - "Tag-vs-config version validation: ConvertFrom-Json on wails.json + -replace '^v','' on github.ref_name, throw on mismatch (skip for workflow_dispatch)"
    - "Two-pass SignPath signing: (1) sign binaries pre-makensis so installer wraps signed DLL/EXE; (2) sign final installer post-makensis"
    - "Secret-gated conditional steps: if: ${{ secrets.SIGNPATH_API_TOKEN != '' }} on every SignPath-adjacent step — pipeline publishes unsigned when gate is open"
    - "Release ldflags bundle: all four -X main.<var>= injections on a single wails build command (Version, aumidOverride, oauthClientID, oauthClientSecret)"
    - "Dry-run vs real-release decision via github.event_name == 'push' AND github.event.inputs.dry_run != 'true' — workflow_dispatch is always artifact-upload only"

key-files:
  created:
    - ".github/workflows/installer-release.yml — 190-line tag-triggered release pipeline"
  modified:
    - "src/app/wails.json — added info.productVersion = '0.0.0' placeholder"
    - ".github/release-template.md — rewritten from v2 (extension/native-host) to v3 (standalone Wails installer)"

key-decisions:
  - "Use '0.0.0' as wails.json info.productVersion placeholder (not '3.0.0' or '1.0.0') — if someone accidentally pushes a v3.0.0 tag before bumping wails.json, the validation step fails loudly. Phase 11 REL-02 owns the bump-to-3.0.0 step."
  - "SignPath v2 (@v2), NOT v1 — CONTEXT D-23 referenced @v1 but docs.signpath.io 2026 + PATTERNS.md §Planner-Facing Correction Log mandate v2. Both SignPath calls use v2."
  - "All four ldflags use main.<var> prefix — corrects CONTEXT D-15's wrong 'github.com/marcfargas/go-mapi/src/app.<var>' path. src/app/toast.go, auth_credentials.go, main.go are all in package main."
  - "Rewrote .github/release-template.md (pre-existing v2.x content) rather than creating fresh — the existing file describes the Chrome/Edge extension + native-host which is obsolete for v3 standalone Wails. Git diff preserves provenance."
  - "workflow_dispatch dry-run path added (plan didn't explicitly require but dry_run: false default + push-event gate on publish step keeps it safe) — lets Marc exercise the pipeline without publishing before Phase 11's real v3.0.0 tag."

patterns-established:
  - "Pattern: Version-authority file validated by CI. wails.json info.productVersion is the canonical version; release workflow rejects tag/config mismatch BEFORE any signing call."
  - "Pattern: Fallback-to-unsigned publishing. Secret-gated SignPath keeps OSS release cadence unblocked if the signing service is unreachable or secrets are unconfigured — users get SmartScreen warning, but release still ships."
  - "Pattern: Two-pass code signing. Sign inner binaries FIRST (DLL + Wails EXE), THEN compile installer, THEN sign installer. Prevents signed-installer-wrapping-unsigned-binary trust drift."
  - "Pattern: Hardcoded production AUMID injection. main.aumidOverride=com.marcfargas.gomapi baked into release builds; matches installer-side .lnk stamp (plan 10-03), enabling persistent Action Center toasts."

requirements-completed: [INST-01, INST-03]

# Metrics
duration: ~18min
completed: 2026-04-20
---

# Phase 10 Plan 06: Release workflow + SignPath + wails.json version authority Summary

**Tag-triggered signed-release pipeline with two-pass SignPath v2, wails.json version-authority validation, and unsigned-fallback publishing — ready for Phase 11 REL-02 to push v3.0.0.**

## Performance

- **Duration:** ~18 min
- **Started:** 2026-04-20T (parallel with plan 10-05)
- **Completed:** 2026-04-20T
- **Tasks:** 3
- **Files modified/created:** 3 (wails.json edit, installer-release.yml create, release-template.md rewrite)

## Accomplishments

- `src/app/wails.json` now exposes `info.productVersion: "0.0.0"` — version authority per D-26. Placeholder value is intentionally wrong for v3 so an accidental `v3.0.0` tag push without bumping wails.json fails the validation step loudly.
- `.github/workflows/installer-release.yml` (190 lines) — tag-triggered (`v*`) + `workflow_dispatch` pipeline with all six errata corrections applied: SignPath @v2 (not v1), `-X main.<var>` ldflags (not `github.com/...src/app.<var>`), `wails.json info.productVersion` schema (not naked `version` key), actions/upload-artifact@v4, softprops/action-gh-release@v2, workflow-level `permissions: contents: write + actions: read`.
- `.github/release-template.md` rewritten: obsolete v2.x content (Chrome/Edge extension, go-mapi-host.exe, native-messaging manifests) replaced with v3.0 single-file Wails installer story. v2.x uninstall warning mirrors plan 10-04 README.
- Three verification layers validate the pipeline integrity: YAML lint, 26 regex acceptance checks on the workflow, 9 regex checks on the release template.

## Task Commits

Each task was committed atomically:

1. **Task 1: Add info.productVersion to src/app/wails.json** — `82b0e54` (feat)
2. **Task 2: Create .github/workflows/installer-release.yml** — `d1be182` (feat)
3. **Task 3: Rewrite .github/release-template.md for v3.0** — `71d251b` (feat)

## Files Created/Modified

- `src/app/wails.json` — added `info.productVersion: "0.0.0"` placeholder. Release workflow reads this via `ConvertFrom-Json` and compares to the tag.
- `.github/workflows/installer-release.yml` — new tag-triggered release pipeline. Structure: checkout → Go/Node/Wails/MinGW setup → version validation → frontend/DLL/Wails build → stage binaries → SignPath pass 1 → makensis → SignPath pass 2 → resolve signed-or-unsigned path → GH Release attach (push only) OR artifact upload (workflow_dispatch).
- `.github/release-template.md` — replaced v2.x content (Chrome extension + native-host) with v3.0 Wails-installer narrative + v2.x uninstall warning + WebView2/Win10-11 requirements + LGPL-3.0 reference.

## Decisions Made

See frontmatter `key-decisions` for the full list. Highlights:

- **Placeholder `0.0.0` vs `3.0.0`:** Keeping the placeholder visibly wrong means an accidental tag push without a wails.json bump fails the validation gate instead of shipping a mislabelled release.
- **SignPath @v2 errata:** PATTERNS.md §Planner-Facing Correction Log entry 2 + RESEARCH §State of the Art flagged CONTEXT D-23's `@v1` as deprecated. Both SignPath calls in this workflow use `@v2`.
- **Ldflags path errata:** All four injection points (`Version`, `aumidOverride`, `oauthClientID`, `oauthClientSecret`) live in `package main` at `src/app/`. CONTEXT D-15's `github.com/marcfargas/go-mapi/src/app.aumidOverride` is wrong; the workflow uses `main.aumidOverride` per PATTERNS.md §Shared Pattern 4.

## Deviations from Plan

### Scope-aware content choice on Task 3

**1. [Rule 3 - Blocking, scope-aware] Rewrite existing .github/release-template.md instead of fresh create**
- **Found during:** Task 3 (Create .github/release-template.md)
- **Issue:** Plan says "CREATE" but the file already existed with v2-era content (Chrome extension download instructions, go-mapi-host.exe, native-messaging manifest under `C:\ProgramData\go-mapi\`). That content is obsolete for v3 standalone Wails and would confuse users downloading v3 installers.
- **Fix:** Rewrote the file with the v3.0 template specified in the plan (Installation / v2.x uninstall / WebView2 / LGPL / README link). Git diff captures the v2→v3 transition cleanly (18 insertions, 74 deletions on one commit).
- **Files modified:** `.github/release-template.md`
- **Verification:** All 9 acceptance-criteria regex checks pass; existing v2 content replaced byte-for-byte in the commit.
- **Committed in:** `71d251b` (Task 3 commit)

---

**Total deviations:** 1 (scope-aware content choice — plan's "CREATE" reinterpreted as "REPLACE" given existing stale v2 content).

**Impact on plan:** Zero scope creep. The plan's action and verification criteria are unchanged; only the git-mechanical operation shifted from "new file" to "modified file."

## Issues Encountered

- **YAML regex-check shell escaping:** First attempt at Task 2's inline `node -e` verification script hit bash escaping issues with `$` and `\$` around the PowerShell `$json` and GitHub Actions `${{ }}` tokens. Resolved by writing the verification script to a temp `.cjs` file, running it, then deleting. All 26 checks pass.
- **LF→CRLF line-ending warnings on commit:** Git flagged the new workflow and template files for LF→CRLF conversion on next touch (Windows filesystem default). Non-fatal; repo has not configured `.gitattributes` text normalization and this matches existing file-endings elsewhere.

## User Setup Required

**External services require manual configuration.** The plan's `user_setup` frontmatter enumerates the required GitHub repo secrets:

- **SignPath (optional — pipeline falls back to unsigned if absent, per D-24):**
  - `SIGNPATH_API_TOKEN` — SignPath Dashboard → API tokens
  - `SIGNPATH_ORG_ID` — SignPath Dashboard → Organization settings → Organization ID (UUID)
  - `SIGNPATH_PROJECT_SLUG` — SignPath Dashboard → go-mapi project settings → Project slug
  - `SIGNPATH_SIGNING_POLICY_SLUG` — SignPath Dashboard → go-mapi project → Signing policies → policy slug
  - SignPath dashboard: ensure the `go-mapi` project signing policy covers `go-mapi.exe`, `go-mapi.dll`, and `go-mapi-setup.exe`.
- **OAuth (carried forward from Phase 8, should already exist):**
  - `GOMAPI_OAUTH_CLIENT_ID`
  - `GOMAPI_OAUTH_CLIENT_SECRET`

No per-machine developer setup required — this plan only touches CI configuration + one JSON file.

## Next Phase Readiness

Phase 11 (REL-02) unblocked:

1. Bump `src/app/wails.json` `info.productVersion` from `"0.0.0"` to `"3.0.0"` on release day.
2. Push tag `v3.0.0`.
3. Workflow fires: tag-vs-wails.json validation passes, DLL + Wails build with all four ldflags, SignPath signs binaries, makensis compiles installer, SignPath signs installer, `softprops/action-gh-release@v2` attaches `go-mapi-setup.exe` to the GH Release at `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`.
4. Optional dry-run dress-rehearsal: trigger `workflow_dispatch` with `dry_run: true`; workflow runs the full pipeline and uploads the installer as a workflow artifact instead of publishing.

No blockers. Plan 10-05 (installer smoke test) runs in parallel and is independent of this file set.

## Self-Check: PASSED

Verification performed:
- `src/app/wails.json` exists and parses as valid JSON with `info.productVersion = "0.0.0"` — verified via `node -e JSON.parse(...)`.
- `.github/workflows/installer-release.yml` exists, parses as valid YAML (`npx js-yaml`), and passes all 26 acceptance-criteria regex checks.
- `.github/release-template.md` exists and passes all 9 acceptance-criteria regex checks (v3.0 title, Installation heading, v2.x uninstall note, WebView2, Win 10/11, LGPL-3.0, go-mapi-setup.exe, README link, no dynamic version interp).
- Commits verified via `git log --oneline -5`: `82b0e54`, `d1be182`, `71d251b` all present on worktree branch.

---
*Phase: 10-installer-migration*
*Completed: 2026-04-20*
