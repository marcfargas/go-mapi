---
name: go-mapi-docs
description: Retrieve, author, revise, consolidate or assess freshness of go-mapi repository documentation. Supports proposed guidance before contract implementation and bounded docs upkeep after changes. Queries stay read-only; capture owns distinct work-record placement.
---

# Work with go-mapi documentation

Complete the selected knowledge operation here. Preserve the requested readers,
sources, write scope and home already chosen by capture. A distinct work-record
need belongs to [go-mapi-capture](../go-mapi-capture/SKILL.md); do not send the same
knowledge payload back to capture, a router or a maker.

## Retrieve or assess

Open an explicit path/section first with `Get-Content -LiteralPath` and enough
context to preserve qualifications. Otherwise choose the relevant home from the
[repository map](references/repository-map.md), then use scoped `rg --files` and
`rg -n` searches. Follow only links needed for the question. Use `git log -- <path>`
and `git show <revision>:<path>` for dated claims. Cite actual sections/symbols,
historical revision where needed, and relevant uncommitted inputs.

Check behavioral claims against current source/configuration. Inspect Just recipes,
script parameters and effects for commands, schemas/tests for contracts. Source
can establish implemented logic, not runtime acceptance or historical rationale.
Keep documented reasons separate from inference and proposals separate from current
behavior. A missing link or scoped search does not prove absence. Retrieval and
report-only freshness checks make no writes, including corrective notes.

## Write or consolidate

Amend established coverage before adding a focused document and its entrypoint
link. Repository Markdown is the supported knowledge interface; no publishing
provider, dedicated checker or private docs binding is established. Do not create
a new knowledge store, tracker or `.planning/` directory.

Use available **mafe-si:technical-writing** for composition/review and
**mafe-si:explain-system** for bounded mechanism research. Without them, retain
useful existing structure, lead with the reader's task, state prerequisites and
effects before commands, and include exact interfaces, observable outcomes,
supported recovery and authoritative links. Preserve attribution, dates, unresolved
uncertainty and unrelated content. Their absence must not block local docs work.

Before a user/operator contract changes, delivery can use the smallest useful
example/runbook marked **proposed** in its existing home; delivery retains execution
and sequencing. After implementation, reconcile affected commands/setup/operations
with verified results before completion. Keep unimplemented or unverified limits;
no-impact code changes require no documentation edit.

For consolidation, search incoming filenames/anchors and inspect outgoing relative
links before editing. Merge equivalent claims while retaining meaningful
differences; do not invent redirects or stable page IDs. Update all in-scope
callers and verify targets/sections. Report an out-of-scope required caller rather
than silently breaking navigation or claiming the move complete.

Apply scoped UTF-8 patches and read each resulting whole document back. Review
`git diff -- <paths>` for meaning, qualifications and links. Verify documented
commands statically unless a runtime trial is already authorized. Build/setup,
Sandbox, registration, certificates and live OAuth/Gmail have effects; docs work
does not authorize them or installing a checker. Historical ignored results are
not fresh candidate evidence. Do not run the full suite for prose-only changes.

Return the resulting reference/answer, actual checks and material limits. Keep
source consistency, isolated execution and live integration distinct. Editing
does not authorize commits, publication, external writes, schedules or broader
maintenance audits.
