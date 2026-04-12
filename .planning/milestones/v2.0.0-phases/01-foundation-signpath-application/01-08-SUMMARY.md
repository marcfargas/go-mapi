---
plan: 01-08
phase: 01-foundation-signpath-application
requirement: SIGN-01
status: deferred-with-draft
completed: 2026-04-10
checkpoint_type: human-verify
---

# Plan 01-08 Summary: SignPath Filing Checkpoint — DEFERRED

## Outcome

**Draft ready, filing deferred by user decision.**

Phase 1 closes on the code side (all FOUND-01..06 requirements shipped) and on the draft side (`SIGNPATH-APPLICATION.md` exists, complete, reviewed). The actual filing of the SignPath Foundation OSS application is deferred to Marc's own schedule — it is not a blocker for advancing to Phase 2.

## User decision

During the Plan 01-08 checkpoint, Marc chose **"Defer filing + fix license discrepancy to LGPL-3.0-or-later"**. The rationale:

1. The SignPath Foundation OSS application is Marc's action — Claude cannot submit it (no API, form is web-only, requires Marc's identity and signature).
2. The Chrome Web Store listing does not exist yet, so filing now would require a placeholder in Section 7 of the draft. Marc prefers to defer filing until either (a) the CWS listing is live or (b) Marc decides explicitly to file with a placeholder.
3. The pre-existing license discrepancy flagged by the draft (`package.json: GPL-3.0-only`, `README.md: License TBD`, project convention LGPL-3.0) should be resolved **before** filing so the SignPath reviewer sees consistent license metadata.

## What was fixed during this checkpoint

Per Marc's decision, the license alignment tech debt was resolved during Plan 01-08 closure (commit `5cdee3b`):

| File | Before | After |
|---|---|---|
| `package.json` `license` field | `GPL-3.0-only` | `LGPL-3.0-or-later` |
| `LICENSE` (repo root) | Full GPL-3.0 text (674 lines) | Full canonical LGPL-3.0 text (165 lines) |
| `COPYING` (repo root) | — | Full canonical GPL-3.0 text (674 lines, moved from old `LICENSE`) |
| `README.md` License section | "TBD / all rights reserved" | LGPL-3.0-or-later with canonical references |

Standard LGPL project layout: `LICENSE` holds the LGPL-3.0 additional-permissions text; `COPYING` holds the underlying GPL-3.0 text that LGPL references. Both texts fetched directly from `gnu.org/licenses/` to avoid transcription errors.

## What Marc still needs to do before filing

These items are **NOT** Phase 1 scope — they live as a standing TODO on Marc:

- [ ] Verify `https://signpath.org/apply` is the current SignPath Foundation OSS program URL.
- [ ] Decide: file with "Chrome Web Store listing pending" note, or wait for CWS publication.
- [ ] Publish the Chrome Web Store listing (separate, out-of-roadmap work).
- [ ] Confirm SignPath Foundation still accepts individual maintainers (not only organizations).
- [ ] Final read-through for confidentiality (no employer/client references crept in).
- [ ] Replace the Chrome Web Store placeholder in Section 7 with the real URL or the "listing pending" note.
- [ ] Paste Sections 2-7 into the SignPath form; do NOT paste Sections 1 or 8 (those are for Marc's reference only).
- [ ] Record the filing date and reference number (if SignPath provides one) back into this SUMMARY.md as a follow-up update when filing happens.

## Phase 1 closure rationale

Phase 1's stated goal (per ROADMAP.md) is "Land the small, mechanical refactors and async paperwork that everything else in v2.0.0 depends on". All six FOUND-* requirements are shipped and verified (FOUND-01 race fix, FOUND-02 version constant, FOUND-03 Gmail baseURL, FOUND-04 env var + CLI flag, FOUND-05 C++ extract, FOUND-06 manifest templates). The "async paperwork" portion (SIGN-01) has its *Claude-side* deliverable shipped — the draft. The *human-side* deliverable (actual filing) is explicitly async and does not block Phase 2/3/4 from starting. Phase 3 (installer + signing) only becomes blocked on SignPath approval when the CI signing step is wired, and Phase 3 has an explicit SIGN-03 fallback for the unsigned path.

Per the CONTEXT.md decision, "Phase 1 completes when the draft exists AND Marc confirms during Plan 08's human verification that he has filed the application OR made a deliberate decision to defer filing." Marc has made the deliberate decision to defer. Phase 1 is complete.

## SignPath follow-up tracking

When Marc does file, he should:

1. Update the `status:` frontmatter of this file from `deferred-with-draft` to `filed-awaiting-review` (or `filed-approved`, `filed-rejected` as appropriate).
2. Record the filing date and the SignPath ticket/reference ID here.
3. If approved, Phase 3 will consume this to wire `SIGN-02` (CI signing step) and `SIGN-04` (stable GitHub Releases URL).
4. If rejected or the review hangs beyond Phase 3's timeline, Phase 3 ships via `SIGN-03` (unsigned fallback + SmartScreen guidance in release notes).
