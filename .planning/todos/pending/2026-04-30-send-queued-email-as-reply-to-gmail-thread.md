---
created: 2026-04-30T10:51:00.000Z
title: Send a queued email as a reply to an existing Gmail thread (rethreading)
area: ui
files:
  - src/app/frontend/src/lib/components/
  - src/app/app.go
  - internal/mapi/gmail.go
  - src/app/settings.go
---

## Problem

Users frequently want a Send-to-Mail-recipient draft to be threaded
under an existing Gmail conversation rather than starting a new
top-level email. Example: "here's the report you asked for" — should
land as a reply in the original request thread, not as a fresh email
the recipient has to mentally reconcile.

Today every draft is created as a fresh top-level email. Users have
to: send the draft, find the original thread in Gmail, copy the
content into a reply, send the reply, delete the original draft.
That's enough friction that they often just don't bother.

## Solution

TBD — sketch:

- New AppSettings field: `RethreadingFilter` (string, default
  `in:inbox`). User-editable in the app settings.
- Per-queue-item action: "Reply to thread…" button on the queue row
- When clicked: call Gmail API
  `users.threads.list(q=<RethreadingFilter>, maxResults=20)` to fetch
  candidate threads (subject, snippet, last-sender, last-date)
- Render in a popover / modal: thread list, scrollable, with subject
  + snippet + date. User picks one.
- Draft creation: instead of `CreateDraft` building a fresh
  `users.drafts.create` payload, set:
  - `message.threadId` = selected thread ID
  - `In-Reply-To` header = Message-ID of the latest message in that
    thread (fetch via `users.messages.get` on the last message)
  - `References` header = thread's References chain + the
    last-message Message-ID
  - Subject prefixed with `Re: ` if not already
- Backend: extend `internal/mapi/gmail.go` to take an optional
  `replyTo *ThreadReplyContext` arg with thread ID + the reply
  headers; existing path stays unchanged when nil.
- Cache thread list briefly (~30s) per session so reopening the
  picker doesn't re-fetch.

Open questions:
- Scope: just `users.threads.list` with a free-form filter, or also
  surface "Sent" / "Starred" / per-label scoping in the UI? The
  filter setting + Gmail's query syntax already covers it; probably
  no extra UI needed.
- OAuth scope: current scopes are `gmail.compose` + `gmail.send` —
  do we need `gmail.readonly` (or just `gmail.metadata`) to list
  threads + get headers? Probably yes for `messages.get` headers.
  This is a reauth event for existing users — needs careful UX.
- Auto-draft mode: rethreading is inherently manual (user picks the
  thread). In auto-draft mode, this feature is hidden / disabled per
  queue item.
- Error cases: filter returns 0 threads, filter is invalid, network
  fails — clear error states, fall back to "create as new email".
- Subject preservation: if user edited the subject (see related todo
  on edit-in-queue), do we still force `Re: <thread subject>`? Probably
  honour user edit; just prepend `Re: ` if missing.

Related todos:
- 2026-04-30-edit-recipients-subject-body-in-queue-ui.md (subject
  editability interacts with reply subject handling)
- 2026-04-30-merge-multiple-queued-emails-into-one.md (thread reply
  + merge: are these compatible? probably mutually exclusive at first)
