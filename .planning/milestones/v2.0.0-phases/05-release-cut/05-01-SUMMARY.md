---
phase: 05-release-cut
plan: 01
subsystem: release
tags: [ci, docs, interceptor, cpp, gcc-warning, gh-cli, release-runbook]

# Dependency graph
requires:
  - phase: 04-test-suite-completeness-e2e
    provides: "PHASE-4-FINDING-02 (json_writer.h:36 -Wcomment warning) and E2E-SPIKE unresolved-risks list for first e2e.yml run"
  - phase: 03-inno-setup-installer-signing-distribution
    provides: "installer-smoke.yml (authoritative INST-01..07 verification)"
provides:
  - "json_writer.h:36 warning-free comment (REL-04 closed)"
  - "05-MANUAL-STEPS.md runbook with REL-01 gh workflow run commands, sign-off checklist, and first-run flake watch list"
  - "Placeholder headings for REL-05/REL-06/REL-07 (stable insertion points for Plan 04)"
affects: [05-04-release-uat-and-milestone-rearchive, 05-release-cut]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Marc-owned manual runbook pattern (.planning/phases/XX/XX-MANUAL-STEPS.md) for steps the executor sandbox cannot perform (gh auth, git push, admin UAT)"

key-files:
  created:
    - .planning/phases/05-release-cut/05-MANUAL-STEPS.md
  modified:
    - src/interceptor/json_writer.h

key-decisions:
  - "PHASE-4-FINDING-02 fixed with forward-slash substitution (option C from findings doc) — one-line change, zero behavior impact, path in comment only"
  - "REL-01 documented as a copy-pasteable Marc-runbook (per D-02) rather than attempted via sandbox gh CLI which has no auth"
  - "MANUAL-STEPS.md seeded with REL-05/06/07 placeholder headings so Plan 04 has stable insertion points (avoids churn-on-append)"

patterns-established:
  - "Phase manual runbook file: one .md with per-requirement sections, each section holding the exact copy-paste shell commands, expected conclusions, and first-line fallback guidance for known risks"

requirements-completed: [REL-01, REL-04]

# Metrics
duration: ~8min
completed: 2026-04-11
---

# Phase 05 Plan 01: CI Trigger Docs + json_writer Fix Summary

**Closed PHASE-4-FINDING-02 with a one-line forward-slash swap in `src/interceptor/json_writer.h:36` and authored the Phase 5 MANUAL-STEPS runbook documenting Marc's exact `gh workflow run` command sequence for triggering installer-smoke, e2e, and go-race-nightly on develop.**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-04-11T07:52Z
- **Completed:** 2026-04-11T07:56Z
- **Tasks:** 2 / 2
- **Files modified:** 2 (1 created, 1 edited)

## Accomplishments

- Eliminated the GCC `-Wcomment` warning on `json_writer.h:36` so CPPTEST-02's first CI run on `windows-latest` shows a clean MinGW build log (REL-04 closed).
- Produced `.planning/phases/05-release-cut/05-MANUAL-STEPS.md` — a single copy-paste runbook Marc opens alongside an authenticated `gh` terminal to fire the three Phase 5 CI workflows and verify their conclusions, including the first-run flake watch list sourced from `04-E2E-SPIKE.md` §"Unresolved risks".
- Seeded REL-05/06/07 placeholder headings in the runbook so `05-04-release-uat-and-milestone-rearchive-PLAN.md` can append without touching REL-01 content.

## Task Commits

Each task was committed atomically with `--no-verify` (parallel worktree convention):

1. **Task 1: Close PHASE-4-FINDING-02 (REL-04)** — `8adb63f` (fix)
2. **Task 2: Author 05-MANUAL-STEPS.md REL-01 section (REL-01)** — `a4e128c` (docs)

## Files Created/Modified

- `src/interceptor/json_writer.h` (line 36) — `%TEMP%\go-mapi\` → `%TEMP%/go-mapi/` inside the `WriteMailToFile` doc-comment. Kills the `-Wcomment` warning by removing the trailing backslash that GCC was interpreting as a line-continuation inside a `//` comment.
- `.planning/phases/05-release-cut/05-MANUAL-STEPS.md` — created. Contains:
  - Prerequisites (gh auth, working dir, clean develop)
  - `## REL-01:` with three command blocks (`installer-smoke.yml`, `e2e.yml`, `go-race-nightly.yml`), each with `gh workflow run` + `gh run list --json` verifier + `gh run watch` pattern
  - First-run flake watch list (5 risks from `04-E2E-SPIKE.md`, each with first-line mitigation)
  - REL-01 sign-off checklist (three `"success"` gates)
  - Placeholder headings for REL-05, REL-06, REL-07

## Decisions Made

- **Fix option C (forward slash)** chosen over option A (backtick wrapping) or option B (drop the trailing char): forward-slash is the most idiomatic path expression for a doc comment, symmetric (`%TEMP%/go-mapi/`), and avoids any ambiguity with Markdown/editor rendering of backticks inside C++ comments.
- **REL-01 stays a Marc-manual runbook** rather than being retried via a sandbox `gh` invocation: confirmed by Phase 5 CONTEXT §D-02 — the executor sandbox has no `gh auth login` state and cannot dispatch workflows. Documenting the commands is the executor-side output; triggering them is Marc-side.
- **REL-05/06/07 placeholder headings seeded in this plan** instead of waiting for Plan 04 to create them: reduces merge risk when Plan 04 appends, and gives Plan 04 stable anchors to reference.

## Deviations from Plan

None — plan executed exactly as written. Task 1 matched the pinned acceptance criteria (one line changed, no `.cpp` touched, no whitespace churn), and Task 2's verification grep for `## REL-01:` + three `gh workflow run` command literals + the `04-E2E-SPIKE.md` reference + the three placeholder headings all pass on the first write.

## Issues Encountered

None.

## User Setup Required

None - the runbook itself IS the user-setup artifact. Marc runs the commands in `05-MANUAL-STEPS.md` §REL-01 between Wave 1 and Wave 2 of Phase 5 execution.

## Next Phase Readiness

- REL-04 closed (one of 7 Phase 5 requirements). REL-01 documented (ready for Marc to execute). Phase 5 requirement progress after this plan: 2/7 (REL-01 docs ready, REL-04 fixed).
- Downstream plans in Wave 1 (05-02 sandbox hardening, 05-03 README rewrite) are unblocked — they depend on nothing this plan produced.
- Plan 05-04 (release-uat-and-milestone-rearchive) has three stable insertion points (`## REL-05:`, `## REL-06:`, `## REL-07:`) in `05-MANUAL-STEPS.md` to append to.
- Between Wave 1 and Wave 2, Marc runs the REL-01 section of the runbook to get the three `windows-latest` CI workflows green on develop. Only after that sign-off is done should Wave 2 (release + UAT) begin.

## Self-Check

- [x] `src/interceptor/json_writer.h` modified — FOUND
- [x] `.planning/phases/05-release-cut/05-MANUAL-STEPS.md` created — FOUND
- [x] Commit `8adb63f` (Task 1 fix) — FOUND
- [x] Commit `a4e128c` (Task 2 docs) — FOUND
- [x] `grep -n "%TEMP%/go-mapi/" src/interceptor/json_writer.h` returns line 36 — PASS
- [x] `grep -nE 'go-mapi\\$' src/interceptor/json_writer.h` returns empty — PASS
- [x] 3 × `gh workflow run` command literals present in MANUAL-STEPS.md — PASS
- [x] REL-05/06/07 placeholder headings present — PASS

## Self-Check: PASSED

---
*Phase: 05-release-cut*
*Plan: 01*
*Completed: 2026-04-11*
