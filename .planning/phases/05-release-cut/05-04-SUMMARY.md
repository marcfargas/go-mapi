---
phase: 05-release-cut
plan: 04
subsystem: release-ops
tags: [runbook, uat, milestone-archive, github-releases, installer-release, gsd-complete-milestone, smartscreen, rel-05, rel-06, rel-07]

# Dependency graph
requires:
  - phase: 05-release-cut
    provides: "Plan 01 left the MANUAL-STEPS runbook with REL-01 filled in and REL-05/06/07 placeholder headings; Plan 04 fills those three placeholders in-place"
  - phase: 05-release-cut
    provides: "Plan 02 hardened tests/sandbox/ so REL-06 can fall back to Windows Sandbox if marcwin unavailable"
  - phase: 05-release-cut
    provides: "Plan 03 rewrote README install flow; REL-06 Step 2 SmartScreen walkthrough mirrors that README copy for what-users-actually-read parity"
provides:
  - "Fully filled-in 05-MANUAL-STEPS.md runbook: REL-05 tag push + installer-release.yml watch + curl -IL verification, REL-06 UAT handoff summary + sign-off, REL-07 /gsd:complete-milestone v2.0.0 rerun + post-condition verification"
  - "05-UAT.md fill-in-the-blank checklist template with 50 checkboxes across 10 UAT steps and a three-way Ship/Block disposition"
  - "Every REL-01..07 requirement now has a concrete landing place Marc can execute top-to-bottom"
affects: [05-release-cut-finalization, v2.0.0-shipping, milestone-lifecycle]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Documentation-only plans can be executed in an autonomous=false envelope — the plan writes the runbook, the user runs the runbook"
    - "Placeholder-replacement pattern: Plan 01 leaves well-known placeholder lines, Plan 04 Edit-replaces them in-place instead of appending"
    - "UAT checklists use bracket-placeholder fields ([bytes], [seconds], [free text]) that Marc fills during the session and commits as the authoritative record"

key-files:
  created:
    - ".planning/phases/05-release-cut/05-UAT.md"
    - ".planning/phases/05-release-cut/05-04-SUMMARY.md"
  modified:
    - ".planning/phases/05-release-cut/05-MANUAL-STEPS.md"

key-decisions:
  - "REL-05 verification is grep-concrete: curl -IL + gh release view + InstallPrompt.tsx cross-reference, not just 'check the URL'"
  - "REL-06 keeps the full checklist in 05-UAT.md and only mirrors a summary in MANUAL-STEPS.md to preserve single-source-of-truth for the UAT record"
  - "UAT disposition forces a three-way PASSED / PASSED-WITH-NOTES / FAILED with ship decision so v2.0.0 ships-or-blocks is never ambiguous"
  - "REL-07 documents /gsd:complete-milestone v2.0.0 idempotency and the roll-back path (git reset --hard origin/develop) so partial archives are recoverable"

patterns-established:
  - "Phase 5 runbook is now top-to-bottom executable: REL-01 (Plan 01) -> REL-05/06/07 (Plan 04) in one file with sign-off checklists between sections"
  - "UAT template uses PowerShell Test-Path probes for filesystem + registry state verification — aligned with INST-01..07 acceptance criteria from Phase 3"

requirements-completed: [REL-05, REL-06, REL-07]

# Metrics
duration: 20min
completed: 2026-04-11
---

# Phase 5 Plan 04: Release UAT and Milestone Re-archive Summary

**Two documentation deliverables that close Phase 5: the MANUAL-STEPS runbook now covers REL-05 tag-push + verification, REL-06 UAT handoff, and REL-07 /gsd:complete-milestone rerun; and a new 05-UAT.md fill-in-the-blank checklist Marc completes during the real-Windows-box UAT session.**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-04-11T07:52:00Z
- **Completed:** 2026-04-11T08:12:00Z
- **Tasks:** 2
- **Files modified:** 1 (05-MANUAL-STEPS.md)
- **Files created:** 2 (05-UAT.md, 05-04-SUMMARY.md)

## Accomplishments

- `05-MANUAL-STEPS.md` REL-05 section filled: preconditions (3 CI workflows green), `git tag -a v2.0.0` + `git push origin v2.0.0`, `gh run watch` on `installer-release.yml`, `curl -IL` on the stable releases URL, `InstallPrompt.tsx` cross-reference grep, and a 6-item sign-off checklist.
- `05-MANUAL-STEPS.md` REL-06 section filled: environment selection (marcwin vs Windows Sandbox), 8-step procedural summary pointing at `05-UAT.md`, fail-mode branching (fix-on-develop / document / defer), and a 4-item sign-off checklist.
- `05-MANUAL-STEPS.md` REL-07 section filled: preconditions (REL-05/06 complete), D-07 rationale for re-archival, `/gsd:complete-milestone v2.0.0` invocation with its 5 documented effects, 4-command verification block, 6-item sign-off checklist, and idempotency / rollback guidance.
- `05-UAT.md` created as a 10-step fill-in-the-blank checklist with 50 checkboxes covering: download, SmartScreen walkthrough, UAC + installer wizard, post-install filesystem state (4 `Test-Path` probes), post-install registry state (6 `Test-Path` probes including all 5 Chromium browsers), extension load, MISSING->READY transition + one-time success toast (EXT-06 / PHASE-4-FINDING-01), real MAPI trigger via Send to Mail recipient, Gmail draft creation (the ship gate), and uninstall cleanup (4 `Test-Path` verifications).
- Phase 5 runbook is now a single document Marc can follow top-to-bottom from CI triggering through milestone re-archive with nothing left to interpret.

## Task Commits

Each task was committed atomically:

1. **Task 1: Append REL-05 / REL-06 / REL-07 sections to 05-MANUAL-STEPS.md** - `1ec835b` (docs)
2. **Task 2: Create 05-UAT.md manual UAT checklist template** - `98dde90` (docs)

**Plan metadata commit:** TBD (orchestrator owns the final docs commit that also touches STATE.md / ROADMAP.md)

## Files Created/Modified

- `.planning/phases/05-release-cut/05-MANUAL-STEPS.md` - REL-05/06/07 placeholder lines replaced in-place with full runbook sections. File now covers REL-01 (Plan 01) + REL-05/06/07 (this plan); no `*(Filled in by Plan 04.)*` placeholders remain.
- `.planning/phases/05-release-cut/05-UAT.md` - New fill-in-the-blank UAT checklist template, 172 lines, 50 checkboxes, 10 UAT steps, three-way Ship/Block disposition. Committed to `develop` before REL-07 runs.
- `.planning/phases/05-release-cut/05-04-SUMMARY.md` - This file.

## Decisions Made

Followed the plan's pre-documented decisions verbatim:

- **REL-05 verification is grep-concrete** (plan spec): chosen over "check the URL manually" because the `curl -IL` / `gh release view` / `InstallPrompt.tsx` triple gives zero-interpretation evidence.
- **UAT checklist lives in a standalone file, not inlined in MANUAL-STEPS.md**: keeps the runbook short, makes the UAT session record a single committed artifact with Marc's timestamp and SHA256 for later audit.
- **Three-way UAT disposition (PASSED / PASSED-WITH-NOTES / FAILED)**: avoids the ambiguous "mostly passed" middle ground that would block ship/no-ship.
- **REL-07 documents `/gsd:complete-milestone` idempotency and rollback**: partial archives are recoverable via `git reset --hard origin/develop` + re-invocation; no manual edits to STATE.md or MILESTONES.md.

## Deviations from Plan

None — plan executed exactly as written.

### Infrastructure Note (not a plan deviation)

Initial first-attempt edits to `05-MANUAL-STEPS.md` were routed to `C:/dev/go-mapi/.planning/...` (the parent repo path) instead of the worktree path `C:/dev/go-mapi/.claude/worktrees/agent-ac791b45/.planning/...`. The parent repo is a separate git working directory with its own checkout — the edits were reverted there via `git checkout --` and re-applied via the Edit tool targeting the full worktree path. Both tasks then committed cleanly on the worktree branch `worktree-agent-ac791b45`. No content was lost; the fix added ~3 minutes of bookkeeping to the plan duration.

## Issues Encountered

One early tool-routing snag (described above in Infrastructure Note) where absolute file paths without the worktree prefix resolved to the parent repo's copy of the same file. Resolved by explicit absolute-path targeting to the worktree directory for all subsequent Edit / Write calls. No content loss.

## User Setup Required

None — this plan produces two documentation artifacts. The documented runbook steps (tag push, UAT session, milestone re-archive) are Marc-owned and explicitly out-of-scope for this plan's execution (per `autonomous: false` and D-02).

## Next Phase Readiness

- Wave 2 of Phase 5 (this plan) is complete. Plans 01, 02, 03, and 04 are merged; Phase 5 Wave 2 orchestrator can collect and finalize.
- Post-Wave-2 Marc-owned manual sequence is ready to execute from a single runbook (`05-MANUAL-STEPS.md`) plus a single UAT record template (`05-UAT.md`):
  1. REL-01: trigger the three CI workflows via `gh workflow run`
  2. REL-05: push `v2.0.0` tag + verify release publication
  3. REL-06: fill in `05-UAT.md` during a real-Windows-box session
  4. REL-07: run `/gsd:complete-milestone v2.0.0` to close the milestone
- No blockers on future work from this plan. The v2.0.0 ship gate is now a documentation-complete manual sequence; v2.0.1 signed re-cut remains explicitly deferred per D-01.

## Self-Check: PASSED

Verified after writing this SUMMARY.md:

- `.planning/phases/05-release-cut/05-MANUAL-STEPS.md` exists, contains "git push origin v2.0.0" (2 matches), "git tag -a v2.0.0", "curl -IL https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe", "gh run watch", "05-UAT.md", "/gsd:complete-milestone v2.0.0", "milestone_complete", "SIGNPATH_API_TOKEN"; contains 4 "sign-off checklist" occurrences (>=4 required); contains 0 "Filled in by Plan 04" occurrences; contains 0 "v2.0.0-rc" occurrences.
- `.planning/phases/05-release-cut/05-UAT.md` exists, contains "## UAT Session", "Send to", "Gmail draft", "SmartScreen", "MISSING", "READY", "Uninstall", "PASSED", "FAILED", "Ship decision", "com.gomapi.host"; contains 50 "[ ]" checkboxes (>=30 required).
- Commits `1ec835b` and `98dde90` exist in `git log` on `worktree-agent-ac791b45`.

---
*Phase: 05-release-cut*
*Plan: 04 — release-uat-and-milestone-rearchive*
*Completed: 2026-04-11*
