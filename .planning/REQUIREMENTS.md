# Requirements: go-mapi

**Defined:** 2026-04-12
**Core Value:** A non-technical Windows user can install go-mapi once and have every "Send to Mail recipient" action appear as a Gmail draft — without touching a terminal, a toolchain, or a registry editor.

## v2.1.0 Requirements

Requirements for v2.1.0 Release Pipeline milestone. Each maps to roadmap phases.

### Changesets Foundation

- [ ] **CS-01**: Changesets monorepo workspace configured with `.changeset/config.json` and `privatePackages: { version: true, tag: true }`
- [ ] **CS-02**: `src/native-host/package.json` stub created as private workspace package for host version tracking
- [ ] **CS-03**: Root `package.json` `workspaces` field includes both `src/extension` and `src/native-host`
- [ ] **CS-04**: Extension and host each have independent semver tracks with per-package git tags (`go-mapi-extension@X.Y.Z`, `go-mapi-host@X.Y.Z`)
- [ ] **CS-05**: Fine-Grained PAT (`CHANGESET_TOKEN`) configured as repo secret with `contents: write` and `pull-requests: write` scopes
- [ ] **CS-06**: Version Packages PR auto-created by `changesets/action@v1.7.0` on push to `main` when changesets exist

### Version Source Migration

- [ ] **VER-01**: Extension build reads version from `src/extension/package.json` instead of root `package.json`
- [ ] **VER-02**: Go host build reads version from `src/native-host/package.json` via ldflags
- [ ] **VER-03**: Installer build reads version from `src/native-host/package.json`
- [ ] **VER-04**: `manifest.json` version auto-synced via lifecycle script on changeset version bump (strips prerelease suffixes for CWS integer-only format)

### Extension Publishing

- [ ] **PUB-01**: `publish-extension.yml` workflow auto-publishes extension ZIP to Chrome Web Store on extension version bump
- [ ] **PUB-02**: Same workflow auto-publishes to Edge Add-ons via `birchill/edge-addon-upload@v1.1.0` (API v1.1 credentials)
- [ ] **PUB-03**: CWS OAuth credentials stored as repo secrets (`CWS_EXTENSION_ID`, `CWS_CLIENT_ID`, `CWS_CLIENT_SECRET`, `CWS_REFRESH_TOKEN`)
- [ ] **PUB-04**: Edge Add-ons credentials stored as repo secrets (`EDGE_API_KEY`, `EDGE_CLIENT_ID`, `EDGE_PRODUCT_ID`)

### Host Release

- [ ] **REL-01**: `installer-release.yml` converted from tag trigger to `workflow_dispatch` with version input
- [ ] **REL-02**: GitHub Release auto-created on host version bump with installer `.exe` and `.sha256` sidecar
- [ ] **REL-03**: Stable download URL `releases/latest/download/go-mapi-setup.exe` verified working

### Pipeline Integration

- [ ] **PIPE-01**: `release-pipeline.yml` orchestrates changesets action, detects which packages bumped, dispatches appropriate publish workflows
- [ ] **PIPE-02**: Legacy `release.yml` retired after at least one successful end-to-end release via new pipeline
- [ ] **PIPE-03**: Extension-only changeset fires only extension publish; host changeset fires only host release; combined changeset fires both

## Future Requirements

### Operational

- **OPS-01**: Automated Edge API key rotation reminder (72-day expiry)
- **OPS-02**: Monthly CWS credential health-check workflow
- **OPS-03**: Per-package CHANGELOG.md auto-generated from changeset summaries

## Out of Scope

| Feature | Reason |
|---------|--------|
| npm registry publishing | Both packages are private — no npm publish step |
| Auto-publish on every push to develop | CWS rate limits and review queue flooding |
| Changesets bot PR comments | Overkill for solo maintainer |
| Host self-update detection | Re-running installer is acceptable |
| Per-package CHANGELOG.md files | Deferred to OPS-03; changeset summaries in PR are sufficient for now |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| CS-01 | Phase 6 | Pending |
| CS-02 | Phase 6 | Pending |
| CS-03 | Phase 6 | Pending |
| CS-04 | Phase 6 | Pending |
| CS-05 | Phase 6 | Pending |
| CS-06 | Phase 6 | Pending |
| VER-01 | Phase 6 | Pending |
| VER-02 | Phase 6 | Pending |
| VER-03 | Phase 6 | Pending |
| VER-04 | Phase 6 | Pending |
| PUB-01 | Phase 7 | Pending |
| PUB-02 | Phase 7 | Pending |
| PUB-03 | Phase 7 | Pending |
| PUB-04 | Phase 7 | Pending |
| REL-01 | Phase 8 | Pending |
| REL-02 | Phase 8 | Pending |
| REL-03 | Phase 8 | Pending |
| PIPE-01 | Phase 9 | Pending |
| PIPE-02 | Phase 9 | Pending |
| PIPE-03 | Phase 9 | Pending |

**Coverage:**
- v2.1.0 requirements: 20 total
- Mapped to phases: 20 ✓
- Unmapped: 0

---
*Requirements defined: 2026-04-12*
*Last updated: 2026-04-12 — traceability filled after roadmap creation*
