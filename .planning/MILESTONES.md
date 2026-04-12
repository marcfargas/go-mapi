# Milestones

## v2.1.0 Release Pipeline (capped) (Shipped: 2026-04-12)

**Phases completed:** 1 of 4 originally planned (Phases 7-9 dropped)
**Plans:** 3

**Key accomplishments:**

- Changesets monorepo configured with two private workspace packages (`src/extension`, `src/native-host`) on independent semver tracks
- Version authority migrated from root `package.json` to per-package files; build scripts updated
- Version Packages CI workflow created with `changesets/action@v1.7.0` and `CHANGESET_TOKEN` Fine-Grained PAT wiring

### Scope change

Phases 7-9 (extension publishing pipeline, host release pipeline, pipeline integration) were dropped on 2026-04-12 after the strategic decision to replace the browser extension with a standalone Wails desktop app in v3.0. Auto-publish infrastructure for the extension would have been retired within weeks. Ten requirements (PUB-01..04, REL-01..03, PIPE-01..03) dropped with the phases. See `.planning/notes/2026-04-12-architecture-reeval-wails.md`.

---

## v2.0.0 Installer UX + Test-Suite Completeness + Release Cut (Shipped: 2026-04-12)

**Phases completed:** 5 phases, 24 plans, 19 tasks

**Key accomplishments:**

- (none recorded)

---
