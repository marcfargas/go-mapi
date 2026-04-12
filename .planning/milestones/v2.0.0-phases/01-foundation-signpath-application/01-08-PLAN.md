---
phase: 01-foundation-signpath-application
plan: 08
type: execute
wave: 3
depends_on: [07]
files_modified:
  - .planning/phases/01-foundation-signpath-application/01-08-SUMMARY.md
autonomous: false
requirements: [SIGN-01]

must_haves:
  truths:
    - "Marc has personally confirmed that he has reviewed the SIGNPATH-APPLICATION.md draft and filed the SignPath Foundation OSS application via their web form"
    - "The confirmation, including any SignPath case/ticket number and the filing date, is recorded in the plan SUMMARY so Phase 3 SIGN-02 can reference it"
    - "If Marc decides NOT to file yet (e.g. waiting for the Chrome Web Store listing to go live first), that decision is documented with the reason and the expected revisit date"
  artifacts:
    - path: ".planning/phases/01-foundation-signpath-application/01-08-SUMMARY.md"
      provides: "Record of Marc's filing confirmation (or deliberate deferral) including ticket number and date"
      contains: "SignPath"
  key_links:
    - from: ".planning/phases/01-foundation-signpath-application/01-08-SUMMARY.md"
      to: ".planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md"
      via: "filing record references the draft that was filed"
      pattern: "SIGNPATH-APPLICATION"
---

<objective>
Human-verification checkpoint for SIGN-01. The SignPath Foundation OSS application is an asynchronous, human-filed process — Claude cannot file it (no API, form is web-only, requires Marc's identity and consent). This plan pauses execution, presents the draft to Marc, and waits for Marc to confirm he has reviewed and filed it (or made a deliberate decision to defer filing).

Purpose: Phase 1 completes when (a) the draft text exists (Plan 07) AND (b) Marc confirms the application is either filed or deliberately deferred. Without this checkpoint, SIGN-01 would be incorrectly marked complete after Plan 07 runs — but a drafted-but-unfiled application does not start the SignPath review clock, which is the entire purpose of doing this in Phase 1.
Output: A `01-08-SUMMARY.md` file recording Marc's confirmation (or deferral decision), including any SignPath ticket/case number and the filing date, so Phase 3 SIGN-02 can reference it.
</objective>

<execution_context>
This plan is the human-verification half of SIGN-01. It depends on Plan 07 (which produces the draft). It is NOT autonomous — it requires Marc's explicit confirmation.

Per CONTEXT.md SIGN-01 decisions: "Phase 1 completes when (a) draft text exists in the repo and (b) Marc confirms 'filed' during verification."

Per the phase planning context special constraint 1: "Phase verification includes Marc confirming 'filed' — mark the verification task as requiring human confirmation."

This plan contains a single checkpoint task. The executor MUST NOT mark SIGN-01 complete until Marc has explicitly responded. "Deliberate deferral" is an acceptable resume signal as long as Marc provides a reason and an expected revisit date — in that case, Phase 1 still completes (because the decision is intentional and documented), and Phase 3's SIGN-02 will re-check the filing status.

**Why this is a separate plan from Plan 07**: Plan 07 is an autonomous drafting task (pure Claude work). Plan 08 is a human-only checkpoint. Combining them into one plan would make Plan 07 non-autonomous and block parallel Wave 1 execution. Separating them lets Plan 07 run in Wave 1 parallel with all the other foundation refactors, while Plan 08 is the sole blocking item in Wave 3.
</execution_context>

<context>
@.planning/phases/01-foundation-signpath-application/01-CONTEXT.md
@.planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md
</context>

<tasks>

<task type="checkpoint:human-verify" gate="blocking">
  <name>Task 1: Marc reviews and files (or defers) the SignPath application</name>
  <files>.planning/phases/01-foundation-signpath-application/01-08-SUMMARY.md</files>
  <read_first>
    - .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md (the draft produced by Plan 07)
    - .planning/phases/01-foundation-signpath-application/01-07-SUMMARY.md (confirming Plan 07 completed cleanly)
    - .planning/phases/01-foundation-signpath-application/01-CONTEXT.md SIGN-01 section (re-read the locked decisions so you understand what "complete" means for this checkpoint)
  </read_first>
  <action>
    This is a `checkpoint:human-verify` task — the executor MUST halt and wait for Marc's explicit response. Do not auto-approve, do not skip, do not infer Marc's decision from context. The executor's job in this task is to:

    **Step 1 — Present the draft to Marc:**
    Use the `<what-built>` and `<how-to-verify>` blocks below as the presentation text. Display them to Marc clearly so he can review the draft and walk through the pre-filing checklist.

    **Step 2 — Wait for Marc's response:**
    Accept one of the three resume signals listed in `<resume-signal>` below:
    - `filed [ticket] [date]` — application has been submitted
    - `deferred [reason] [expected-revisit-date]` — deliberate decision not to file yet
    - `blocked [what-needs-resolving]` — something prevents filing and requires a follow-up

    **Step 3 — Write the outcome to 01-08-SUMMARY.md:**
    After Marc responds, write `.planning/phases/01-foundation-signpath-application/01-08-SUMMARY.md` using the exact template in the `<output>` section at the bottom of this plan. Fill in all bracketed fields based on Marc's verbatim response. Preserve the response text verbatim in the "Decision" section so Phase 3 SIGN-02 has an unambiguous source of truth.

    **Step 4 — Signal completion:**
    If Marc responded "filed" or "deferred", this plan is complete — return control to the phase orchestrator. If Marc responded "blocked", do NOT mark the plan complete — instead, surface the blocker to the orchestrator so it can either resolve the blocker in-place or create a follow-up plan to handle it.

    **Scope discipline:**
    - Do NOT file the application on Marc's behalf — SignPath's form is web-only and requires Marc's personal consent as the maintainer
    - Do NOT make any changes to the repository code, tests, or configuration — this plan is pure documentation
    - Do NOT touch SIGNPATH-APPLICATION.md (that is Plan 07's artifact; if Marc finds issues during review, create a follow-up revision task, do not edit in-place here)
    - Do NOT modify REQUIREMENTS.md — the phase orchestrator handles traceability table updates at phase close
    - Do NOT auto-mark SIGN-01 complete if Marc has not explicitly confirmed "filed"
  </action>
  <what-built>
    Plan 07 produced a complete draft of the SignPath Foundation OSS application text at `.planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md`. The draft contains:
    - Project identity and licensing (LGPL-3.0)
    - A defensive explanation of why MAPI handler replacement is a standard Windows mechanism, not interception
    - Privacy posture statement
    - Links to the repository and Marc's GitHub profile
    - A clearly marked Chrome Web Store listing placeholder
    - A pre-filing checklist of action items
  </what-built>
  <how-to-verify>
    **Step 1 — Review the draft:**
    Open `.planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md` in your editor. Read the full text. Pay special attention to:
    - Section 4 (What the Binaries Do) and Section 5 (Why MAPI Handler Replacement is Not Interception) — these are the reviewer-facing defensive framing. Are you comfortable with the wording? Is there anything that could be misread by a security-sensitive reviewer?
    - Section 2 (Project Identity) — verify the license statement (LGPL-3.0) matches your intent. Per the draft's note, package.json currently says GPL-3.0-only and README says "License TBD" — resolve this discrepancy before filing.
    - Section 7 (Links) — confirm the GitHub URL is correct and the repository is public. Decide what to do about the Chrome Web Store listing placeholder.
    - Section 8 (Pre-Filing Checklist) — walk through each item.

    **Step 2 — Resolve the pre-filing checklist items:**
    At a minimum:
    - Align the LGPL-3.0 license metadata across package.json, README.md, and add a LICENSE file if missing. (This is separate tech debt — address it in a follow-up commit on develop, it is not part of this plan's scope.)
    - Confirm https://github.com/marcfargas/go-mapi is public
    - Verify the SignPath OSS application URL (https://signpath.org/apply or wherever their current OSS program form lives)
    - Decide: file now with a "CWS listing pending" note, or wait until the Chrome Web Store listing is published

    **Step 3 — File the application (or deliberately defer):**
    If filing now:
    1. Visit the SignPath OSS program application URL
    2. Copy-paste sections from SIGNPATH-APPLICATION.md into the corresponding form fields
    3. Submit
    4. Record the ticket/case number (if SignPath issues one) and the filing date
    5. Respond with: "filed" plus the ticket number and date

    If deliberately deferring:
    1. Write down the reason (e.g. "waiting for Chrome Web Store listing to publish so the application includes a live URL")
    2. Write down the expected revisit date
    3. Respond with: "deferred" plus the reason and expected revisit date

    **Step 4 — Record the outcome:**
    After your response, Claude will create `.planning/phases/01-foundation-signpath-application/01-08-SUMMARY.md` recording your decision. Phase 3 SIGN-02 will reference this summary to know the filing status.
  </how-to-verify>
  <verify>
    <automated>test -f .planning/phases/01-foundation-signpath-application/01-08-SUMMARY.md && grep -Eq "^\*\*Status:\*\* (Filed|Deferred|Blocked)" .planning/phases/01-foundation-signpath-application/01-08-SUMMARY.md</automated>
  </verify>
  <acceptance_criteria>
    - Marc has explicitly responded with one of: "filed", "deferred", or "blocked"
    - If filed: the ticket/case number (if issued) and the filing date are captured in the SUMMARY
    - If deferred: the reason and the expected revisit date are captured in the SUMMARY
    - `.planning/phases/01-foundation-signpath-application/01-08-SUMMARY.md` is written with the outcome (grep: `test -f .planning/phases/01-foundation-signpath-application/01-08-SUMMARY.md` succeeds)
    - The SUMMARY file contains a Status line set to one of Filed / Deferred / Blocked (grep: `grep -Eq "^\*\*Status:\*\* (Filed|Deferred|Blocked)" .planning/phases/01-foundation-signpath-application/01-08-SUMMARY.md`)
    - The SUMMARY file contains the literal text of Marc's response verbatim (no paraphrasing)
    - SIGN-01 can be marked complete in the requirements traceability table IF Marc responded "filed"; if Marc responded "deferred", SIGN-01 stays Planned with a note pointing at the SUMMARY for context; if "blocked", the phase orchestrator is notified
  </acceptance_criteria>
  <resume-signal>
    Respond with one of:

    1. **"filed [ticket-number] [YYYY-MM-DD]"** — application submitted, with optional ticket number and filing date. Example: `filed SP-2026-0412 2026-04-10` or just `filed 2026-04-10` if no ticket number was issued.

    2. **"deferred [reason] [expected-revisit-date]"** — deliberate decision not to file now, with reason and when to revisit. Example: `deferred waiting for CWS listing 2026-05-15`.

    3. **"blocked [what-needs-resolving]"** — there is a blocker (e.g. SignPath Foundation no longer accepts applications, URL has moved, the LGPL-3.0 license alignment is not done yet). Claude will then help resolve the blocker before retrying the checkpoint.

    After your response, Claude will create the SUMMARY file and return control to the phase orchestrator.
  </resume-signal>
  <done>
    Marc has given an explicit filed / deferred / blocked response, the response is captured verbatim in 01-08-SUMMARY.md, the Status line in the SUMMARY matches the response category, and the orchestrator has been notified of the outcome (implicit via plan completion).
  </done>
</task>

</tasks>

<verification>
- Marc has explicitly responded with filed / deferred / blocked
- The response content is captured verbatim in 01-08-SUMMARY.md
- If "filed": SIGN-01 is marked Complete in REQUIREMENTS.md traceability table (this is done by the phase orchestrator at phase close, not by this plan directly)
- If "deferred" or "blocked": a clear note is added to the SUMMARY explaining the state, and the phase orchestrator knows SIGN-01 is not yet closed
</verification>

<success_criteria>
- Human verification received (explicit response from Marc)
- Outcome recorded in 01-08-SUMMARY.md
- Phase can progress to closure (with SIGN-01 either Complete, or Planned-with-deferral-note)
- No silent passes — if Marc does not respond, this plan stays blocked and the phase does not close
</success_criteria>

<output>
After Marc responds, create `.planning/phases/01-foundation-signpath-application/01-08-SUMMARY.md` with the following structure:

```
# Plan 08 Summary: SignPath Application Filing Confirmation

**Status:** [Filed | Deferred | Blocked]
**Date of decision:** YYYY-MM-DD
**Decision recorded by:** Marc Fargas (via /gsd-execute-phase 1 checkpoint)

## Decision

[verbatim text of Marc's response]

## Details

### If Filed
- SignPath ticket / case number: [captured from response]
- Filing date: [captured from response]
- Draft used: .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md
- Next step: Phase 3 SIGN-02 will reference this SUMMARY to check approval status before the code-signing workstream starts

### If Deferred
- Reason: [captured from response]
- Expected revisit date: [captured from response]
- Blocker to resolve: [if any]
- Draft preserved at: .planning/phases/01-foundation-signpath-application/SIGNPATH-APPLICATION.md
- Next step: Phase 3 SIGN-03 (unsigned fallback path) is the gating requirement for release if SignPath approval has not landed by then

### If Blocked
- Blocker: [captured from response]
- Resolution plan: [to be drafted with Marc before retrying this checkpoint]

## SIGN-01 Traceability

- Requirement: SIGN-01 ("An application to the SignPath Foundation OSS program is filed...")
- Mapped to phase: Phase 1 (Foundation & SignPath Application)
- Mapped to plans: Plan 07 (draft) + Plan 08 (this plan — filing confirmation)
- Status after this plan: [Complete | Planned with deferral note | Blocked]
```

Fill in all bracketed fields based on Marc's response. Commit the SUMMARY to git with message `docs(phase-01): record SignPath application filing decision`.
</output>
