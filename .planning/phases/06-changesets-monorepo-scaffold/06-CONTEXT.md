# Phase 6: Changesets Monorepo Scaffold - Context

**Gathered:** 2026-04-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Configure changesets with two private workspace packages (extension + host), migrate version authority from root package.json to per-package package.json files, and auto-create a Version Packages PR when changesets exist on main. Publishing workflows are Phase 7 (extension) and Phase 8 (host).

</domain>

<decisions>
## Implementation Decisions

### Version migration strategy
- **D-01:** Both packages start at version 2.1.0 (clean start for new milestone; extension is 2.0.0 in CWS, host reports 2.0.0 via READY message — first changeset will bump from 2.1.0)
- **D-02:** Remove the `version` field from root `package.json` entirely — signal that root has no version authority. npm allows this for private packages.
- **D-03:** Build scripts (`build:native-host`, `build:native-host:debug`, `src/interceptor/build.ps1`) must be updated to read version from their respective per-package `package.json` instead of root

### Develop/main branch flow
- **D-04:** Changeset files are added on the `develop` branch as part of normal work. When develop merges to main, `changesets/action@v1.7.0` detects accumulated changesets and creates a Version Packages PR on main.
- **D-05:** Version Packages PR requires manual merge — no auto-merge. This gives a final human gate before publish workflows trigger in later phases.

### manifest.json version sync
- **D-06:** Vite injects the version from `src/extension/package.json` into the output `manifest.json` at build time. The source `manifest.json` uses a placeholder or static value; Vite overwrites it during build. Existing `vite.config.ts` is the integration point.
- **D-07:** Development builds use `{version}-dev+{commithash}` format (e.g., `2.1.0-dev+a3b4c5d`). Vite strips prerelease/build metadata to produce CWS-compliant integer-only version for production builds.

### Tag format transition
- **D-08:** Clean break from `v*` tags to per-package tags: `go-mapi-extension@X.Y.Z` and `go-mapi-host@X.Y.Z`. Old `v*` tags remain in git history but no new ones are created.
- **D-09:** `installer-release.yml` will switch from tag trigger to `workflow_dispatch` (planned for Phase 8) — no interim tag compatibility needed in this phase.

### Claude's Discretion
- Exact `.changeset/config.json` structure and options
- How to structure the `src/native-host/package.json` stub (minimal fields)
- CI workflow YAML structure for the changesets action
- Whether to use `changesets/action` commit message format or customize it

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Changesets configuration
- `.planning/REQUIREMENTS.md` — CS-01 through CS-06 define changesets setup requirements; VER-01 through VER-04 define version migration requirements

### Existing build infrastructure
- `package.json` — Root package.json with current build scripts, workspaces config, version field to remove
- `src/extension/package.json` — Extension package with current version 2.0.0
- `src/extension/vite.config.ts` — Vite config where manifest.json version injection will be added
- `src/extension/public/manifest.json` — Extension manifest that needs version injection
- `src/interceptor/build.ps1` — C++ build script that reads version from root package.json (lines 98-104)

### CI workflows to modify
- `.github/workflows/installer-release.yml` — Current tag-triggered installer release (will switch to workflow_dispatch in Phase 8, but version reading changes in this phase)
- `.github/workflows/release.yml` — Legacy release workflow (retirement planned for Phase 9)
- `.github/workflows/build.yml` — Build workflow that may need version source updates
- `.github/workflows/e2e.yml` — E2E workflow with hardcoded version `2.0.0` on line 51

### Go host version injection
- `src/native-host/main.go` — `var Version = "0.0.0-dev"` fallback; receives version via `-ldflags "-X main.Version=..."`

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `src/extension/vite.config.ts` — Already handles extension-specific bundling; natural place to add manifest.json version injection via `transformIndexHtml` or `writeBundle` plugin
- Root `package.json` scripts — All build scripts are PowerShell one-liners that can be updated to read from per-package paths

### Established Patterns
- Version injection via Go ldflags: `go build -ldflags "-s -w -X main.Version=$v"` — pattern stays, only the source of `$v` changes
- Inno Setup version via `/DGOMAPIVersion=` flag — same pattern, source changes
- Root workspaces already partially set up: `["src/extension"]` — just needs `src/native-host` added

### Integration Points
- `package.json` workspaces array — add `src/native-host`
- `src/native-host/package.json` — new file (stub for version tracking)
- `.changeset/config.json` — new file (changesets configuration)
- `.github/workflows/` — new workflow for changesets action (Version Packages PR)
- All build scripts that currently read root version — update to per-package paths

</code_context>

<specifics>
## Specific Ideas

- Dev builds should be identifiable: `{version}-dev+{commithash}` format so local testing always shows a meaningful version string
- CWS requires integer-only version format (e.g., `2.1.0` not `2.1.0-dev+abc123`) — Vite must strip suffixes for production builds

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 06-changesets-monorepo-scaffold*
*Context gathered: 2026-04-12*
