---
name: go-mapi-capture
description: Retain, triage or retrieve go-mapi requests, work breakdowns and deferred observations. Select repository knowledge, retained working material or conversation-only handling; identify missing tracker conventions before tracker-dependent operations. Does not execute recorded work.
---

# Capture go-mapi material

Use this procedure directly for project capture and retrieval. Establish the
checkout and original request, including its readers, sources and write scope.
Recording material does not approve its proposal, execute work, schedule pickup
or mark an outcome complete. A retrieval or report-only request stays read-only.

## Choose purpose and coverage before drafting

1. Follow an explicit reference first. For repository coverage, from the root use
   `rg --files -g '*.md' -g '!node_modules/**' -g '!src/app/vendor/**'`, then
   `rg -n -i -- '<topic>' DEVELOPMENT.md docs src/app/README.md` with a literal
   topic in place of the placeholder. Narrow or change the paths for the selected
   component. Inspect matches and relevant links with
   `Get-Content -LiteralPath '<path>' -Encoding UTF8`. Follow supplied work/PR
   references through an available read interface; inability to read is a gap,
   not proof of no coverage. `git log --oneline -- '<path>'` can locate historical
   accounts, but local files/history cannot establish tracker-wide deduplication.
2. Decide whether to reuse, materially update, create or make no write. Bounded
   work handled by this conversation or an existing PR needs no separate issue
   merely because edits, reviews or checks occurred. Repeated progress with no
   changed meaning warrants no update. Reuse known canonical coverage; do not
   manufacture a retrospective completion ticket.
3. Preserve explicit capture requests and established record requirements. An
   unresolved decision, independently useful obligation or emerging need for
   later pickup can warrant durable work coverage early, even during delivery.
   A tracker name alone establishes neither a creation request nor its conventions.
4. Select the home by purpose and readers before composing:
   - Lasting technical knowledge: the relevant existing README, DEVELOPMENT.md
     or `docs/` document. Pass the selected home, outcome, sources and uncertainty
     directly to [go-mapi-docs](../go-mapi-docs/SKILL.md), which completes the
     knowledge operation. Keep a distinct work-record need here.
   - Provisional designs, review packets and resumable working material: use the
     explicit task destination or available **mafe-si:owner-paths**. Local working
     material is not a shared tracker or canonical product documentation.
   - Work tracking: no project tracker or issue convention is established by the
     inspected repository. A remote URL, issue references and CLI authentication
     do not establish one. See the [evidence and gaps](references/discovery.md).
     Do not invent a TODO file, `.planning/`, configuration, labels or ticket
     hierarchy. Report the missing destination/convention only for the dependent
     operation. Continue independent retrieval or authorized knowledge work.
   - No durable write needed, or writing excluded: give the useful result in the
     conversation. Honor a requested draft without claiming it was retained.

When durable work coverage is warranted but the tracker is unresolved, preserve
the original request, source, remaining decision and next actor in the current
handback. If local working retention is within scope, retain its draft there and
state that shared tracking remains unresolved. Neither a session plan nor that
draft substitutes for a required tracker record; do not silently drop explicit
capture just because its dependent operation cannot yet run.

## Retain locally or triage

Search the selected existing document or working packet before adding another.
For an explicit working-material folder use
`Get-ChildItem -LiteralPath '<selected-folder>' -File` and scoped `rg -n` searches
when it exists; an absent folder has no records to search. Read likely matches
and their source links, including dated completed accounts. Repeated material
should reuse coverage; materially changed meaning should amend the relevant
current account, retaining source and qualifications. Related but independent
outcomes can link rather than duplicate each other.

For an authorized retained working file, resolve the selected task folder portably
with `Join-Path $env:LOCALAPPDATA 'agent-work\retained\go-mapi\<task>'`,
replacing `<task>` with the established task destination.
Check LOCALAPPDATA exists; do not fall back into the repository or guess a user
profile. Only when a file is needed, create the selected directory with
`New-Item -ItemType Directory -Path '<selected-folder>' -Force`. Inspect an
existing target before editing. Use a descriptive task-selected filename and
UTF-8 without a BOM, for example
`[IO.File]::WriteAllText($selectedPath, $body, [Text.UTF8Encoding]::new($false))`
with the selected absolute path and composed body. Read the actual result using
`Get-Content -LiteralPath $selectedPath -Encoding UTF8`; check meaning, sources
and links. This is a writing operation, never part of retrieval.

Retain enough context to resume: the desired outcome or observation, significance,
retrievable source/revision or attribution, uncertainty, open decisions and next
check when known. Separate observed behavior from intended work. Preserve the
original request and authorized limits when retaining a work breakdown supplied
by planning/delivery; record meaningful pieces, decisions, actual dependencies,
authoritative sibling links and remaining acceptance without inventing tickets
for phases or claiming child completion proves integrated delivery. Changed scope
must be supported by a decision, not inferred from a shorter draft.

Triage uses only supplied decisions and vocabulary. Keep ideas, proposed work,
agreed work and verified completion distinct; do not invent priority, deadlines,
acceptance or a schedule. On interruption, retain what happened, what remains and
the next check. Local prose can express these facts without a new schema.

For a **deferred observation** during another task, search relevant existing
coverage, retain a concise source/context and unresolved questions in the selected
authorized home, read back, then resume the original task. A final solution is
unnecessary. Read-only scope means report the observation without writing; a
warning alone establishes neither a substantive observation nor write authority.
Do not capture every speculative remark or execute the deferred work.

## Reconcile consequential handbacks

Before reporting a changed result, blocker or owner decision, compare it with
the known active account and relevant linked current summaries. Reconcile changed
claims within scope; do not scan the backlog. Where a linked knowledge claim needs
an authorized correction, pass that distinct operation to go-mapi-docs. Keep
closed deliveries as dated history, qualifying a misleading present-tense claim
or linking current state instead of continually refreshing old completion records.

When writing a request draft or warranted update, use available
**mafe-si:reporting-for-humans** for the selected readers, purpose, destination,
essential claims and qualifications. Placement and publication stay here. If it
is unavailable, lead with the outcome/problem, retain material decisions or
blockers, remaining acceptance and next actor/action, and link accessible detail.
Compose the whole current account afresh; remove superseded claims and resolved
detours, preserving active requirements, authority, scope and dependencies once.
Inspect both the proposed change and resulting whole body against current sources.
Operational recoverability does not require publishing the entire working packet.
Batch related changes; routine narration and unchanged restrictions stay in the
session. A body correction does not alone warrant a comment or notification.

No tracker create/edit/comment/status operation is supplied here: its provider,
search scope (including closed work), canonical readback and publication policy
must first be established. Do not emulate these operations with local drafts.

## Ownership, handoffs and unsupported intake

Before any provider write, distinguish local retention from sending material to
another project, including knowledge-only contributions. Follow relevant supplied
ownership/dependency links; retain the likely owner, source and uncertainty locally
without contacting it. No project extraction procedure was found; already-formed
local knowledge does not require an extraction ritual. If the request is actually
to evaluate experience for lessons, available **mafe-si:extract-learnings** can
do that bounded selection before retention.

For an authorized outgoing handoff, use the actual project handoff procedure or
available **mafe-si:coordinate-projects** for fresh capture in the receiving
owner's context. If unavailable, report the missing transport/context; do not
write the receiver's records directly. A handoff proposal or local note sends
nothing and launches no work. Preserve any expressly requested single result's
destination, condition and authority; invent no reply duty or followup messages.

Incoming knowledge may use the local docs path when authorized. Preserve attributed
requirements separately from suggestions and return its actual file reference,
created/updated/already-covered disposition and gaps through the invocation only.
Tracker intake, accepted-work pickup, `mafe-pending`, conditional claims, dispatch,
provider deduplication and uncertain-receipt recovery are not implemented. Do not
claim a task ID or acceptance from a draft. For a lost local write receipt, inspect
the same target and source coverage before retrying; distinguish a correction
from a retry. Provider intake needs its complete source key/namespace, closed
coverage search and canonical readback before safe retries can be specified.

Return what was retrieved or retained, its accessible reference, disposition and
remaining gap. Capture grants no implementation, installation, external-write,
communication or completion authority. Complete supported branches here without
returning the original payload to a shared router or invoking a maker.
