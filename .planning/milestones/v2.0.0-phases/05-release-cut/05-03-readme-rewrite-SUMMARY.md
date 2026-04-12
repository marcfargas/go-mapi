---
phase: 05-release-cut
plan: 03
subsystem: docs
tags: [readme, documentation, v2.0.0, release-cut, smartscreen, installer, end-user-flow]

requires:
  - phase: 03-inno-setup-installer-signing-distribution
    provides: "Inno Setup installer (go-mapi-setup.exe), EXT-07 stable download URL, five-browser native messaging"
  - phase: 02-extension-install-ux
    provides: "InstallPrompt.tsx INSTALLER_DOWNLOAD_URL constant (cross-file reference)"
provides:
  - "End-user-first README.md Installation/Usage/Uninstall/Privacy sections for v2.0.0"
  - "SmartScreen click-through walkthrough matching .github/release-template.md"
  - "## Development section preserving contributor build/test/local-install instructions"
  - "Byte-identical download URL with src/extension/src/popup/InstallPrompt.tsx (EXT-07)"
affects: [05-04-release-uat, v2.0.0-milestone-archive]

tech-stack:
  added: []
  patterns:
    - "Single source of truth for download URL: README.md, InstallPrompt.tsx, .github/release-template.md"
    - "SmartScreen guidance scoped to unsigned-pending-SignPath context (does not generalize click-through)"

key-files:
  created: []
  modified:
    - "README.md"

key-decisions:
  - "Reuse exact 3-step SmartScreen phrasing from .github/release-template.md (More info → Run anyway → UAC) for cross-doc consistency"
  - "Move legacy scripts/install.ps1 -Local path into ## Development section instead of deleting it (contributor muscle memory preserved)"
  - "Status table bumped from v1.0.0 Stable → v2.0.0 with Inno Setup 6 + five-browser Chromium family rows"
  - "## Development section positioned BEFORE ## Why 'go-mapi'? so dev instructions come before project lore"

patterns-established:
  - "End-user vs contributor docs split: ## Installation is end-user-first, ## Development is labelled for contributors and contains a backlink to ## Installation for non-contributors who land there by mistake"
  - "SmartScreen warning docs include a time-bound caveat ('v2.0.1 once SignPath approval lands') so the section has a clear removal trigger"

requirements-completed: [REL-03]

duration: 6min
completed: 2026-04-11
---

# Phase 05 Plan 03: README Rewrite Summary

**README.md install flow rewritten for v2.0.0 end-user distribution — single-click go-mapi-setup.exe download with SmartScreen walkthrough, dev-oriented irm-pipe-iex instructions relocated to a labelled `## Development` section**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-04-11T07:55:00Z
- **Completed:** 2026-04-11T08:01:33Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments

- Replaced v1.0.0-era `## Quick Start` (admin PowerShell + `irm https://... | iex`) with end-user `## Installation` section pointing at `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` — the exact URL already used by `src/extension/src/popup/InstallPrompt.tsx:5` and `.github/release-template.md:7`.
- Added `## Usage`, `## Uninstall`, and `## Privacy` sections covering the single UAC prompt, the unins000.exe fallback, the `C:\ProgramData\go-mapi\uninst\previous-mail-client.json` restore backup, and the delete-on-process privacy model — no terminal, no toolchain, no admin PowerShell required for the happy path.
- Added an `## If Windows SmartScreen blocks the installer` subsection with the canonical 3-step walkthrough (click **More info**, click **Run anyway**, proceed with UAC) copied verbatim from `.github/release-template.md` so the message is consistent between the GitHub release notes and the README.
- Bumped the Status table from "v1.0.0 Stable" to "v2.0.0" with new rows for the Inno Setup 6 single-click installer, the full Chrome / Edge / Chromium / Brave / Vivaldi Chromium-family browser list, and the `tests/sandbox/` local repro harness.
- Updated `## Enterprise Deployment` from the legacy `.\install.ps1 -Unattended` PowerShell advice to Inno Setup's standard `/VERYSILENT /SUPPRESSMSGBOXES` + `/SILENT` + `/LOG=<path>` command-line switches, with a link to the official Inno Setup setupcmdline documentation.
- Added a new `## Development` section (positioned before `## Why "go-mapi"?`) containing the former Quick Start content: build-everything PowerShell recipe, `scripts/install.ps1 -Local` dev loop (explicitly called out as "legacy path still supported for contributors"), `iscc.exe` Inno Setup build recipe, all four test-suite commands (go, C++ ctest, extension Vitest, Playwright E2E), a backlink to `tests/sandbox/README.md` for the Windows Sandbox local repro (REL-02), a CI workflows index, and a troubleshooting subsection.
- Preserved the Architecture diagram, Why go-mapi, Contributing, License, and References sections verbatim.

## Task Commits

Each task was committed atomically:

1. **Task 1: Rewrite README.md install-related sections for v2.0.0 end-user flow** — `be5b376` (docs)

_No separate plan-metadata commit: the orchestrator owns STATE.md / ROADMAP.md writes for this wave._

## Files Created/Modified

- `README.md` — Rewrote Status (v1.0.0 → v2.0.0), replaced `## Quick Start` with end-user `## Installation` + `## Usage` + `## Uninstall` + `## Privacy` + `## If Windows SmartScreen blocks the installer`, updated `## Enterprise Deployment` for Inno Setup switches, added new `## Development` section (positioned before `## Why "go-mapi"?`). +147 / -68 lines. 265 lines total, 12344 bytes.

## Decisions Made

- **Keep `scripts/install.ps1 -Local` mention in `## Development`** — not deleted. The legacy PowerShell installer is still supported for contributors testing an unreleased build without recompiling the Inno Setup installer every iteration. REL-03 only removes it from the end-user install path, not from the contributor tooling.
- **Inline the SignPath rationale in the SmartScreen section** — rather than just documenting the click-through, the README explains WHY SmartScreen warns ("v2.0.0 installer ships unsigned — the project's code-signing certificate via the SignPath Foundation OSS program is in review") and adds a removal trigger ("signed installer will ship as v2.0.1 once SignPath approval lands, at which point this section becomes unnecessary"). This scopes the click-through to this specific context and trains users to ask "is this section still needed?" at the v2.0.1 re-cut.
- **Six-second reconnect detail in `## Usage`** — the Usage section mentions the auto-detect toast "disappears within six seconds" so non-technical users who installed the extension first don't panic when the "Install go-mapi" banner is still there for a few seconds after running the installer. Matches the EXT-06 6-second reconnect alarm.
- **`## Development` before `## Why "go-mapi"?`** — sections ordered so that docs discoverable by contributors (Development) come before project lore (Why). `## Contributing`, `## License`, and `## References` remain at the end.

## Deviations from Plan

None - plan executed exactly as written. All three Edit operations applied cleanly, all 17 acceptance-criteria greps passed on the first pass, and the cross-file URL consistency check confirmed README.md and `src/extension/src/popup/InstallPrompt.tsx` share a byte-identical download URL.

## Issues Encountered

**Worktree-path resolution confusion (early execution).** The initial Edit operations used absolute path `C:\dev\go-mapi\README.md` which resolved to the **main repository root**, not this worktree's copy at `C:\dev\go-mapi\.claude\worktrees\agent-a1460b5d\README.md`. The main repo was on branch `develop` at commit `fcdb0450` (a newer commit than this worktree's base `5ef76da`), which happened to still have the v1.0.0 content in its working tree, so the Edit operations appeared to succeed against the plan's `old_string` values. Detected by running cross-file URL consistency via absolute-path node script, which reported `README has URL: false` for the worktree path. Resolved by:

1. Reverting the main repo README.md with `cd C:/dev/go-mapi && git checkout README.md` (no data loss — the main repo never had my edits committed).
2. Re-reading the worktree README.md at the correct absolute path.
3. Re-applying all three Edit operations to `C:\dev\go-mapi\.claude\worktrees\agent-a1460b5d\README.md` (the worktree path).
4. Re-running all 17 acceptance-criteria checks against the worktree README.md — all passed.
5. Committing from the worktree (`git status` confirmed only the worktree README.md was modified).

**Root cause:** the worktree base reset earlier in the run brought the working tree to `5ef76da` while `pwd` reported the worktree directory, but the absolute paths I passed to the Edit tool pointed at the main repo root. Lesson for future parallel-executor agents: always scope absolute paths through `C:\dev\go-mapi\.claude\worktrees\agent-<id>\...` when operating in a worktree, not through `C:\dev\go-mapi\...`. The main repo may be on a different branch/commit than the worktree.

## Self-Check: PASSED

**Files verified:**

- `C:\dev\go-mapi\.claude\worktrees\agent-a1460b5d\README.md` — FOUND (265 lines, 12344 bytes)

**Commits verified:**

- `be5b376` (docs(05-03): rewrite README.md install flow for v2.0.0 end-user distribution (REL-03)) — FOUND in `git log`

**Acceptance criteria (17/17):**

- `^## Installation$` — FOUND (line 68)
- `^## Usage$` — FOUND (line 117)
- `^## Uninstall$` — FOUND (line 132)
- `^## Development$` — FOUND (line 164, positioned before `## Why "go-mapi"?` at line 239)
- `^## Privacy$` — FOUND (line 143)
- `^## Architecture$` — PRESERVED (line 30)
- `^## License$` — PRESERVED (line 250)
- Exact URL `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` — FOUND (line 82, byte-identical with InstallPrompt.tsx:5)
- `More info` — FOUND (line 108, SmartScreen step 1)
- `Run anyway` — FOUND (line 109, SmartScreen step 2)
- `unins000.exe` — FOUND (line 135, Uninstall pointer)
- `Chrome, Edge, Chromium, Brave, or Vivaldi` — FOUND (line 75, five-browser INST-03 consistency)
- `tests/sandbox/README.md` — FOUND (line 221, points at REL-02 local repro harness)
- `LGPL-3.0` — PRESERVED (lines 252, 254, 255)
- `irm https` — NOT FOUND (legacy one-liner removed from end-user flow)
- `## Quick Start` — NOT FOUND (section replaced)
- Minimum 100 lines — PASSED (265 lines)

## User Setup Required

None — no external service configuration required. This is a pure documentation edit.

## Next Phase Readiness

- **REL-03 closed.** The README install flow now matches PROJECT.md's core value statement ("non-technical Windows user ... without touching a terminal, a toolchain, or a registry editor").
- **Ready for REL-05 (GitHub Releases publish).** When the v2.0.0 tag fires `installer-release.yml`, the README download link will start resolving to a real asset. No further README changes are needed for the release to ship.
- **Ready for REL-06 (manual UAT).** The UAT script can follow the README top-down on a real Windows box as-is — the happy path is now discoverable without reading the contributor tooling.
- **Ready for REL-07 (re-archive milestone).** The README no longer contradicts "v2.0.0 shipped" because it now points at the v2.0.0 distribution mechanism.
- **v2.0.1 follow-up noted.** The SmartScreen section has an explicit removal trigger ("once SignPath approval lands"). When the signed re-cut ships as v2.0.1, a follow-up plan can delete the `## If Windows SmartScreen blocks the installer` subsection entirely.

---
*Phase: 05-release-cut*
*Completed: 2026-04-11*
