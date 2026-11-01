# Capture discovery and integration limits

This is current-contract authoring against repository baseline
`96665564724033447e9e5f0b55d684068b9d0540`, not a historical policy reconstruction.
Reinspect relevant evidence when the selected operation changes.

- [DEVELOPMENT.md](../../../../DEVELOPMENT.md) identifies contributors and
  maintainers as its readers and links the user README and administrator guide.
  `docs/` and component READMEs contain existing technical knowledge. Use the
  docs skill's [repository map](../../go-mapi-docs/references/repository-map.md)
  to select a relevant source rather than loading every document.
- The baseline has no AGENTS.md, CLAUDE.md or `.mafe-si.toml`; none supplies
  tracker binding, private-value lookup, issue lifecycle, accepted-work pickup or
  local provenance records. No project extraction or handoff procedure was found.
  The build skill supplies build procedures, not capture conventions.
- The remote is `https://github.com/marcfargas/go-mapi.git`. The implementation
  brief reports an authenticated issue-list request returned HTTP 401. That
  report is an access limit, not evidence that there are no issues or that GitHub
  Issues is the project's selected tracker. No live provider records were written
  or representative issue convention independently verified for this authoring.
- DEVELOPMENT.md mentions `.planning/`, but that directory is absent at the
  baseline. Do not create it or infer an active planning/tracking system from
  stale links. Historical issue/phase identifiers in prose are source context,
  not new work-record requirements.
- `.gitignore` excludes `test-results/` and several local TODO/context filenames.
  An ignore entry does not establish a sanctioned work tracker. Existing ignored
  test results can be evidence when actually present and relevant; they do not
  prove a new run or provide shared request coverage.
- No tracker-specific private configuration mechanism is confirmed. Do not add
  one or store credentials in these skills. Existing OAuth `.env.local` guidance
  is for app development and does not bind a tracker.

The canonical collection is `.agents/skills`, with ordinary-file Claude
forwarders under `.claude/skills`. Capture calls the sibling docs skill directly.
Source placement alone does not establish native discovery or automatic selection.
Shared reporting, extraction, ownership and coordination skills are optional
use-time capabilities, not bundled dependencies or permission grants.
