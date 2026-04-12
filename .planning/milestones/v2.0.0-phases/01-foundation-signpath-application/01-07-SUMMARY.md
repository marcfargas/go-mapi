---
phase: 01-foundation-signpath-application
plan: 07
subsystem: infra
tags: [signing, signpath, oss, distribution, docs]

# Dependency graph
requires:
  - phase: 01-foundation-signpath-application
    provides: Phase 1 context and SIGN-01 implementation decisions from 01-CONTEXT.md
provides:
  - SignPath Foundation OSS application draft text (8 sections, ready for Marc to paste into form)
  - Defensive framing language for reviewer-facing MAPI handler description
  - Pre-filing checklist flagging license metadata discrepancy and Chrome Web Store URL placeholder
affects: [01-08, 03-signing]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Out-of-tree planning documents: SignPath application draft lives in .planning/ so it does not ship in the installer or public releases but is traceable to SIGN-01"

key-files:
  created:
    - .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md
  modified: []

key-decisions:
  - "Defensive framing throughout: zero uses of 'intercept' or 'hooking' in reviewer-facing sections; MAPI handler is consistently framed as standard Windows Mail client registration used by Outlook, Thunderbird, and any other Mail client"
  - "Chrome Web Store URL left as explicit PLACEHOLDER with a forced decision for Marc (file now with 'listing pending' note vs wait until CWS is published) rather than guessing a URL"
  - "License discrepancy (package.json GPL-3.0-only vs README 'License TBD' vs project convention LGPL-3.0) flagged in pre-filing checklist as a must-resolve item before submission, but left out of this plan's scope per the CONCERNS.md tech debt item"
  - "Draft structured in 8 sections so Marc can paste sections 2-7 directly into SignPath form fields while sections 1 and 8 remain for his own pre-filing reference"

patterns-established:
  - "Placeholder identity convention: when drafting external-facing text, use literal PLACEHOLDER/TODO markers and force a decision in a pre-filing checklist rather than inventing URLs or identifiers"

requirements-completed: [SIGN-01]

# Metrics
duration: 6 min
completed: 2026-04-10
---

# Phase 1 Plan 7: SignPath Foundation OSS Application Draft Summary

**SignPath Foundation OSS application draft (140 lines, 8 sections) with defensive MAPI handler framing, LGPL-3.0 declared, CWS URL placeholdered, and a pre-filing checklist flagging the package.json/README license discrepancy for Marc to resolve before submission.**

## Performance

- **Duration:** 6 min
- **Started:** 2026-04-10 (end of 01-06 session)
- **Completed:** 2026-04-10
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments

- Created `.planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` containing the full application text Marc will paste into the SignPath Foundation OSS program form
- All 8 sections present: (1) header/pre-filing checklist, (2) project identity, (3) why signing is needed, (4) what the binaries do, (5) MAPI handler standard-extensibility rebuttal, (6) source/build reproducibility, (7) links, (8) final checklist
- Zero instances of "intercept" or "hooking" in the reviewer-facing text — every mention of the MAPI behavior is framed as "standard Mail client handler registration" identical to how Outlook, Thunderbird, and Windows Mail register
- Privacy posture stated explicitly: no telemetry, transient `%TEMP%` files deleted on process, Gmail-only draft creation, no SMTP send, no auto-start, no background service
- Chrome Web Store URL clearly marked as `PLACEHOLDER — TODO before filing` with two explicit filing options for Marc (file now with "listing pending" note vs wait until CWS publishes)
- License discrepancy between `package.json` (`GPL-3.0-only`), `README.md` ("License TBD"), and project convention (LGPL-3.0) flagged in both pre-filing checklists (sections 1 and 8) as a must-resolve item; tracked to `.planning/codebase/CONCERNS.md`
- No confidential material: verified zero hits for company/firm/group names per the global confidentiality rule

## Task Commits

1. **Task 1: Draft SIGNPATH-APPLICATION.md with defensive framing and all required fields** — `479e218` (docs)

**Plan metadata:** (to be added as part of the final metadata commit)

## Files Created/Modified

- `.planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` — Full application draft with 8 sections, defensive framing, privacy posture, placeholders explicitly marked, and a pre-filing checklist for Marc

## Decisions Made

- **Defensive framing:** The plan called for avoiding "intercept"/"hook" in reviewer-facing text. The draft achieves zero instances of `intercept` in the entire file (verified by grep) and uses "standard Mail client handler", "standard Windows extensibility mechanism", "receives the MAPI call", and "authorized by explicit user consent at install time" consistently. Section 5 is a dedicated rebuttal paragraph that preempts the predictable reviewer concern without itself using the word "intercept".
- **Placeholder strategy:** Rather than guessing URLs for Marc's identity fields, used explicit literal placeholder markers and forced decisions in the pre-filing checklist. The GitHub URL `https://github.com/marcfargas/go-mapi` is used as it matches the existing README URL (verified in README.md lines 84-88), and the GitHub profile URL `https://github.com/marcfargas` matches the global user identity. The Chrome Web Store URL is the only genuine unknown and is marked `PLACEHOLDER`.
- **License declaration:** Per CONTEXT.md and global project convention, the draft states LGPL-3.0-or-later. The pre-filing checklist explicitly flags that the repo metadata (`package.json` currently says `GPL-3.0-only`, `README.md` says "License TBD") must be aligned to LGPL-3.0 before filing. This alignment is NOT done in this plan (out of scope per the plan's execution_context note).
- **Document location:** Kept at `.planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` per CONTEXT.md — out of the repo tree so it does not ship in the installer or public releases, but in planning for traceability to SIGN-01.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## Verification of Acceptance Criteria

All acceptance criteria from the plan verified via grep:

- File exists: ✓ (140 lines)
- `DRAFT` marker present: ✓ (line 3)
- All 8 section headings present: ✓ (sections 1-8 confirmed in grep)
- `LGPL-3.0` mentioned: ✓ (5 matches, ≥2 required)
- License discrepancy flagged: ✓ (2 matches for `GPL-3.0-only|discrepancy|ambiguity`)
- Placeholder/TODO markers for CWS URL: ✓ (2 matches)
- No confidentiality violations: ✓ (0 matches for `BGBL|BLEGAL|BGA|ACM|blegal.dev`, case-insensitive)
- Defensive framing phrases present: ✓ (5 matches for `standard Mail client|standard.*handler|Windows extensibility|user consent`)
- Word "intercept" in reviewer-facing text: ✓ (0 matches — exceeds requirement; plan allowed up to 2 in rebuttal context)
- `GitHub` / `marcfargas` present: ✓ (14 matches)
- `privacy` / `no telemetry` present: ✓ (4 matches)
- File length ≥100 lines: ✓ (140 lines)

## User Setup Required

None — this plan produces a draft document only. Marc's filing action is captured in Plan 08 as a human-verification checkpoint.

## Next Phase Readiness

- SIGN-01 requirement is half-complete: the draft exists. Plan 08 (`01-08-PLAN.md`) is the human-verification checkpoint where Marc confirms he has reviewed, resolved the pre-filing checklist items, and filed the application via SignPath Foundation's OSS program form.
- Phase 1 completes after Plan 08.
- No blockers for Plan 08; it only requires Marc's confirmation.

## Self-Check

Verification performed:

```
test -f .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md → FOUND
git log --oneline --all | grep 479e218 → FOUND: docs(01-07): draft SignPath Foundation OSS application text
wc -l .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md → 140
```

## Self-Check: PASSED

---

*Phase: 01-foundation-signpath-application*
*Completed: 2026-04-10*
