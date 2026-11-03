# Capture destinations and provider operations

Use this reference for issue retrieval, publication, lifecycle or access recovery.
This is a current-contract review against mafe-si 0.1.43, not a reconstruction of
the unknown original maker revision. Project facts were checked at `60e2faa` on
2026-11-02. Recheck operation availability and relevant state at use time.

## GitHub work records

The owner selected GitHub issues in `marcfargas/go-mapi`. The observed capture of
[issue #14](https://github.com/marcfargas/go-mapi/issues/14) retained the requested
CI-duration outcome before separately authorized dispatch. A fresh read confirmed
that canonical record. It illustrates outcome, current state, evidence, constraints
and remaining acceptance; it establishes no mandatory template, labels or scheduler.

Use the connected GitHub tools when available. Inspect their current contracts;
the names below are operation suffixes, independent of a host's tool prefix.

| Operation | Concrete interface |
| --- | --- |
| Search coverage | `github_search_issues`: `query` scoped with `repo:marcfargas/go-mapi is:issue <terms>`; omit the `state` filter to include open and closed work. Repeat focused searches or narrow an incomplete result set; a limited first result is not exhaustive. |
| Read issue | `github_fetch_issue`: `repository_full_name`, `issue_number`. Read canonical state and body; search snippets may omit status. |
| Read discussion | `github_fetch_issue_comments`: `repo_full_name`, `issue_number`. Follow relevant linked decisions. |
| Read PR context | `github_fetch_pr`: `repo_full_name`, `pr_number`; use the available review/discussion tools when relevant. |
| Create warranted issue | `github_create_issue`: `repository_full_name`, `title`, `body`. Preserve the returned canonical URL/number, then fetch it. Do not supply guessed labels, assignees or milestones. |
| Materially edit/status | `github_update_issue`: `repository_full_name`, `issue_number`, and only intended fields such as `body` or `state`. `body` replaces the whole body: read first and preserve unrelated current meaning. Use `state_reason: completed` only with justified closure. Fetch after writing. |

Search relevant current and closed coverage before new issues, including source
references, distinctive requirements and canonical linked records. Reuse actual
coverage; related work is not automatically a duplicate. Reconcile an uncertain
create through matching request/source and canonical readback before considering
a retry. No provider idempotency key is exposed here, so do not claim exactly-once
creation. If ambiguity remains, retain the uncertain result and resolve it rather
than creating another issue. Distinct corrections retain their own source and may
need separate coverage linked to a closed original; do not reopen it automatically.

Recompose active issue bodies for material current-state changes. Use comments
only for a selected discussion, audit need or decision that belongs there, after
inspecting the current comment tool contract. Agent recovery and unchanged
handbacks do not select comments. Return through the requesting invocation;
capture does not send unsolicited acknowledgments or completion messages.

The connected tool inventory currently has no native blocked-by read/add/remove
operation. A prerequisite may be described and linked with its uncertainty, but
that is not a verified native edge. Discover any separately supported authenticated
API before using it; this skill supplies no guessed route or permission workaround.
Missing edge support must not erase a successfully retained issue or trigger a
duplicate intake. Closure of a supplier does not prove the consumer works.

The default branch was read back as `develop` at this review. Recheck GitHub's
actual default branch and closing-reference rules when selecting
PR relationships. A PR may resolve one issue and merely advance another. Retain
each remaining acceptance condition and verify canonical issue status after merge;
do not infer closure from a nondefault-branch merge or a PR description alone.

Earlier `gh` CLI credentials returned HTTP 401 while connected reads succeeded.
These are separate access paths. A CLI failure neither proves absence of issues
nor blocks a working connector. Do not ask for tokens in chat, copy credentials
into skills or repeatedly retry an uncertain write. If no supported access works,
retain impact, uncertainty and the next actor; a local draft is not a shared record.

## Knowledge, retained material and discovery

[DEVELOPMENT.md](../../../../DEVELOPMENT.md) and the docs skill's
[repository map](../../go-mapi-docs/references/repository-map.md) locate maintained
knowledge. `.planning/` was retired in `df17ab2`; historical phase or Perficio
references do not select a current backlog or authorize recreating that tree.

Use the supplied task area or the capture entrypoint's outside-repository retained
location for provisional designs, recovery checkpoints and detailed evidence.
Ignored `test-results/` can supply relevant evidence but is not a work tracker or
proof of a new run. Keep shared issue meaning understandable without local files.

No private tracker configuration, project extraction procedure, pending-work queue
or automatic pickup convention is established. Do not invent one. For an authorized
outgoing handoff use the receiving owner's fresh capture context or available
**mafe-si:coordinate-projects**; local retention and a handoff proposal send nothing.
Issue creation does not authorize a new thread, implementation or scheduling.

The canonical skills live under `.agents/skills`, with ordinary-file Claude
forwarders under `.claude/skills`. Capture calls the sibling docs skill directly.
The active Codex catalog exposes these skills; native Claude loading is not proved
by file placement or structural validation. No AGENTS.md/CLAUDE.md bootstrap is used.
Shared reporting, extraction, ownership and lifecycle skills are optional use-time
capabilities, with local fallbacks in the entrypoint.
