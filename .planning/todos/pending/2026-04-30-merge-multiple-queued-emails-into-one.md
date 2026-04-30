---
created: 2026-04-30T10:49:31.061Z
title: Merge multiple queued emails into one
area: ui
files:
  - src/app/frontend/src/lib/components/
  - src/app/app.go
  - internal/mapi/gmail.go
---

## Problem

When a user generates multiple reports in their desktop apps and uses
"Send to → Mail recipient" on each one, every invocation creates a
separate JSON in the queue → a separate Gmail draft. The user often
wants ONE email containing all the reports, not N separate drafts they
have to manually consolidate inside Gmail.

Today the queue UI treats each entry as an independent draft target.
There's no way to say "take these three queue items and produce one
combined draft" without manually copy-pasting in Gmail.

## Solution

TBD — sketch:

- Multi-select in the queue UI (checkboxes on `QueueRow` or shift-click
  selection)
- New action button "Merge into one draft" visible when ≥2 items selected
- Merge semantics — needs design decisions:
  - Body: concatenate plain-text bodies with separators? Convert all to
    HTML and stack? Use the latest as primary and attach the rest as
    .eml/.txt? User probably wants the bodies inline, separated by
    horizontal rules and source labels ("From: <originApp>").
  - Subject: union of subjects? First subject? "Combined: N emails"?
    Probably let the user edit before sending — the merge produces
    a single draft they review in Gmail anyway.
  - Recipients: union of To/Cc/Bcc, deduped by normalized address
  - Attachments: union all
  - originApp: list each contributing app
- Backend: extend `internal/mapi/gmail.go` MIME builder to accept a
  merged `MailMessage` (or a new `MergedMailMessage` type), or do the
  merge in Go before calling existing `CreateDraft`
- Auto-draft mode interaction: probably skip auto-draft for merge —
  this is inherently a manual-mode feature. Or: a "hold for merge"
  collection mode where queued items aren't auto-drafted while a merge
  collection is active.

Open questions:
- Does Auto-draft mode need to be paused while accumulating items for a
  merge, or is this purely a Manual-mode feature?
- Limit on items per merge (size limits in Gmail API)?
- What happens to the source queue items after a successful merge —
  delete all, keep all, or let user choose?
