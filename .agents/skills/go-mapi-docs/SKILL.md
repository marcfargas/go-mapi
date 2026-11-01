---
name: go-mapi-docs
description: Retrieve, author, revise, consolidate or assess freshness of go-mapi repository documentation. Supports proposed guidance before contract implementation and bounded docs upkeep after changes. Queries stay read-only; capture owns distinct work-record placement.
---

# Work with go-mapi documentation

Complete the selected knowledge operation here. Start with the user's outcome,
readers, reference and write scope. Capture may already have selected the home;
preserve that choice unless evidence exposes a consequential conflict. Do not
send the same payload back to capture or a shared router. A distinct unresolved
work-record need may use [go-mapi-capture](../go-mapi-capture/SKILL.md) without
interrupting a supported knowledge operation. Do not invoke makers in ordinary use.

## Retrieve and answer

From the repository root, open an explicit path/reference first with
`Get-Content -LiteralPath '<path>' -Encoding UTF8`. For a supplied section, read
enough surrounding context to preserve version limits, proposal status and links.
Follow only relationships needed to answer. Do not assume a missing linked file
is current policy or proof that its claim is false.

Without a reference, select a relevant area using the
[repository map](references/repository-map.md). For example:

```powershell
rg --files docs src/app src/installer/msi distribution tests/sandbox -g '*.md' -g '!vendor/**' -g '!**/vendor/**' -g '!**/node_modules/**'
rg -n -i -- 'queue-v1|MailMessage' DEVELOPMENT.md docs internal/mapi/protocol.go
git rev-parse HEAD
git status --short
```

Adapt the topic and scope to the question; do not scan all sources as a ritual.
Inspect a match in context and check relevant source/configuration when a behavior
claim matters. Use `git log --oneline -- '<path>'` and
`git show '<revision>:<path>'` for a dated claim. Cite the actual file/section or
symbol; include revision when historical identity matters and disclose relevant
uncommitted changes. Do not imply a commit identifies uncommitted text.

Answer with the supported claim, source and material qualification. Say what was
not found or accessible without treating a scoped search as exhaustive. Retrieval,
explanation and report-only freshness assessment make no content/configuration
writes, including observation records or corrective notes. For bounded mechanics
or historical-rationale research, use available **mafe-si:explain-system**; retain
this knowledge operation and distinguish documented reasons from inference.

## Author or revise

Search existing coverage before adding a document. Amend the relevant established
home; add a focused `docs/` document only when the authorized knowledge does not
fit existing coverage, and link it from the relevant existing entrypoint. See
the map for readers and source boundaries. Do not create a new knowledge store,
tracker or `.planning/` directory.

Use available **mafe-si:technical-writing** for composition/review, supplying
the readers, purpose, sources and selected home; keep writes and readback here.
If unavailable, retain the existing useful structure, lead with the reader's
task, explain prerequisites and side effects before commands, use exact interface
names and recognizable placeholders, and link authoritative detail. Include
observable outcomes and recovery where supported. Keep current behavior,
proposed changes, historical evidence and interpretation distinct. Preserve
attribution, dates/version limits, unresolved uncertainty and unrelated content.

Before implementation of a user/operator-facing contract, delivery can call this
procedure for the smallest useful proposed guide, example or runbook in the
established home. Mark intended behavior **proposed**; describe unsettled decisions
without asserting availability. The delivery owner retains implementation and
sequencing. After code/configuration/infrastructure changes, and before completion,
assess only affected claims, commands, examples, setup and operations. Reconcile
proposals against the verified result; retain unimplemented or unverified limits.
No-impact changes need no docs edit. This procedure supplies that lifecycle branch;
its presence does not prove an external delivery caller invokes it automatically.

Apply the scoped patch with an available editor/patch tool. Use UTF-8, preserve
relative Markdown links and existing formatting, and avoid unrelated rewrites.
Review `git diff -- '<affected-paths>'` with paths passed as separate arguments;
read every affected document back from the filesystem with `Get-Content`.
Check retained meaning, sources, qualifications and navigation, not just headings.
Return the file references and changes; editing docs does not authorize a commit,
PR, push, website publication, provider write or execution of the documented work.

## Move or consolidate

When relocation/consolidation is requested, identify the affected paths, headings
and explicit anchors before editing. Search old filenames, link targets and section
fragments with scoped `rg -n -F -- '<target>'` searches across relevant Markdown
entrypoints and callers. Read matches to distinguish real incoming references
from ordinary mentions; inspect relative outgoing links from moved files too.
The baseline has Markdown files and relative links, not a demonstrated wiki or
redirect service; do not invent stable page IDs or aliases.

Combine equivalent claims while preserving meaningful qualifications, sources and
differences. Keep conflicting accounts distinct until evidence resolves them.
Update affected navigation/references within scope and verify the new target and
section exist. If a required caller or reference is outside edit scope, report
the integration gap; do not silently break it or claim a completed move. Retain
unrelated material and history. Use an editor/patch tool for scoped moves; do not
recursively move directories to reorganize the project as a side effect.

## Assess freshness and verify within authority

Compare the selected claim with its relevant code, recipes, tests or workflow.
For commands, inspect the recipe and invoked script's parameters and side effects.
For contracts, inspect the maintained schema and representative tests. Relevant
code can establish implemented logic; it cannot by itself prove runtime success,
installation, historical rationale, RDS behavior or current live service health.
Keep contradictory sources and their dates visible until the evidence supports
a replacement. Report-only assessment returns findings without repairs.

The baseline has no dedicated Markdown lint/link recipe. For an authorized docs
edit use `git diff --check -- '<affected-paths>'`, scoped incoming-link searches,
and direct target/heading readback. These checks do not prove rendered anchors or
example execution. If a renderer/checker becomes available, inspect its actual
contract before using it. Do not install a tool merely because a check is missing.
When no runtime trial is permitted, label command validation as static inspection.

Inspect current `justfile`, `package.json`, relevant scripts and
`.github/workflows/ci.yml` before selecting any additional check. Build recipes,
`just prepare-windows`, installer/Sandbox harnesses and product commands have
effects; docs verification is not authority to install tools, stop another
Sandbox, register DLLs/services, touch host mail settings or run live OAuth/Gmail.
Use only an already authorized isolated destination for behavior trials and
retain evidence through the task's selected working-material convention. Existing
ignored `test-results/` files are historical evidence unless tied to the tested
candidate. Do not run the full software suite for prose-only changes without a
claim that needs it.

Finish with the resulting reference or answer, supported checks and material gaps.
Distinguish source consistency, isolated execution and live integration. Bounded
upkeep does not imply a full documentation audit, automatic maintenance schedule,
observation database or toolbelt/provenance maintenance during ordinary docs use.
