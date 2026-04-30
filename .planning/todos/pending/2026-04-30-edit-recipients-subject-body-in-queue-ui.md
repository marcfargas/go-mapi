---
created: 2026-04-30T10:51:00.000Z
title: Edit recipients / subject / body of a queued email in the UI
area: ui
files:
  - src/app/frontend/src/lib/components/
  - src/app/frontend/src/lib/queue.ts
  - src/app/app.go
  - internal/mapi/protocol.go
  - internal/mapi/gmail.go
---

## Problem

Today the queue UI is read-only. The user can either accept whatever
the source desktop app produced (recipients, subject, body) and create
a draft as-is, or they have to wait for the draft to land in Gmail and
edit it there. That's a context switch the user shouldn't need.

Common cases that surface this:
- Source app put the wrong recipient (e.g., default workgroup address)
- Subject line is auto-generated and unhelpful
- Body needs a personal note prepended before sending
- Need to add Cc / Bcc that the source app doesn't expose

## Solution

TBD — sketch:

- Edit affordance per queue row — pencil icon or "Edit" button that
  opens the row into an inline editor (or a side panel)
- Editable fields: To, Cc, Bcc, Subject, Body (and probably the
  attachment list — at least removal)
- Body editor: needs to handle both plain-text and HTML emails
  cleanly. Candidate WYSIWYG libraries that play well with Svelte 5:
  - Tiptap (ProseMirror-based, well-maintained) — needs a Svelte
    wrapper; svelte-tiptap exists but check Svelte 5 runes compatibility
  - Quill — older but mature; less native-feeling
  - Just contenteditable + a small custom toolbar — minimal-deps, but
    edge cases (paste, lists, links) get hairy fast
  Probably Tiptap if the wrapper supports Svelte 5; otherwise
  contenteditable + sanitize.
- Persistence: edits should mutate the queue JSON in place
  (`%LOCALAPPDATA%\go-mapi\queue\<id>.json`) so a restart preserves
  the edit. New backend method on App: `UpdateQueuedEmail(id, fields)`.
- Validation: re-run `validateMailMessage` after edits; bad addresses
  should highlight inline rather than fail draft creation silently.
- Auto-draft mode interaction: edits should pause auto-draft for that
  specific item until the user explicitly hits "Create draft" — or
  drop the item from the auto-draft queue while editing.

Open questions:
- Plain-text vs HTML: keep the user's choice, or always convert to
  HTML for editing and back to plain on save? (HTML→plain conversion
  is lossy; plain→HTML is fine.)
- Should attachments be editable (rename, remove, add)? Probably yes
  for remove; add is more involved (file picker → copy into queue dir).
- Undo / cancel: Esc should revert; Ctrl+Z within editor.
