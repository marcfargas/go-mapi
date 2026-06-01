---
id: SEED-002
status: dormant
planted: 2026-06-01
planted_during: v3.0 Wails Pivot — Phase 11 close-out (paused on go-mapi-www)
trigger_when: when relevant
scope: unknown
---

# SEED-002: Consider Azure App Insights for feedback & bug reporting plus opt-in telemetry

## Why This Matters

_To be filled in. Run `/gsd:capture --seed --enrich SEED-002` to add context._

Captured intent (from planting): feedback collection and bug reporting are wanted
("the first two we need"); opt-in telemetry is a maybe — "might be useful down the
road." The three are deliberately ranked, not bundled.

⚠️ **Privacy-baseline tension:** the project's stated privacy model is "No telemetry,
no long-term storage of message content, no network calls outside the Gmail API"
(CLAUDE.md). Any telemetry — even opt-in — and any Azure App Insights egress would be
a new network destination that the current LGPL-3.0 / privacy-by-design posture does
not allow. Enriching this seed must reconcile feedback/bug-reporting transport with
that baseline (e.g. user-initiated report upload vs. background telemetry), and the
opt-in-telemetry leg should stay explicitly gated behind user consent.

## When to Surface

**Trigger:** when relevant

This seed will surface during `/gsd:new-milestone` when the milestone scope matches
(e.g. a post-GA "observability / user feedback" milestone).

## Scope Estimate

**Unknown** — run `/gsd:capture --seed --enrich SEED-002` to estimate effort.

Likely splits into three independently-sizable legs:
1. In-app feedback capture (needed)
2. Bug reporting / crash report submission (needed)
3. Opt-in telemetry (deferred / nice-to-have)

## Breadcrumbs

- `CLAUDE.md` → Constraints + Cross-Cutting Concerns → **Privacy** ("No telemetry, no
  long-term storage of message content, no network calls outside the Gmail API"). This
  is the constraint any App Insights integration must be reconciled against.
- `src/app/logging.go` → existing file-based logging (`%APPDATA%\go-mapi\app.log`) is
  the natural local source for any user-initiated bug report bundle.

## Notes

_Captured via one-shot seed capture. Enrich with trigger, why, and scope at your convenience._

User ranking at plant time: feedback + bug reporting = needed; opt-in telemetry = future maybe.
