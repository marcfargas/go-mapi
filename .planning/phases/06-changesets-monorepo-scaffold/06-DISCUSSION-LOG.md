# Phase 6: Changesets Monorepo Scaffold - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-12
**Phase:** 06-changesets-monorepo-scaffold
**Areas discussed:** Version migration strategy, Develop/main branch flow, manifest.json version sync, Tag format transition

---

## Version Migration Strategy

### Starting version

| Option | Description | Selected |
|--------|-------------|----------|
| Both at 2.0.0 | Matches current shipped version. Continuity for users. | |
| Both at 2.1.0 | Clean start for the new milestone. | ✓ |
| Extension 2.0.0, Host 1.0.0 | Host never had its own semver track. | |

**User's choice:** Both at 2.1.0
**Notes:** Clean start for v2.1.0 milestone

### Root package.json version

| Option | Description | Selected |
|--------|-------------|----------|
| Freeze at 2.0.0 | Root stays private, version never bumps again. | |
| Remove the version field | Signal that root has no version authority. | ✓ |
| Keep synced to host version | Root tracks the host version. | |

**User's choice:** Remove the version field
**Notes:** Cleaner signal that root has no version authority

---

## Develop/Main Branch Flow

### Changesets workflow

| Option | Description | Selected |
|--------|-------------|----------|
| Changesets on develop, PR to main | Add changeset files on develop. Version Packages PR on main merge. | ✓ |
| Changesets only on main | Only add changeset files when merging to main. | |
| Changesets on develop + auto-merge | Develop auto-merges to main on CI green. | |

**User's choice:** Changesets on develop, PR to main
**Notes:** Fits existing git workflow

### Auto-merge gate

| Option | Description | Selected |
|--------|-------------|----------|
| Manual merge | Review Version Packages PR before merge. Final human gate. | ✓ |
| Auto-merge on CI green | Version Packages PR merges automatically. | |

**User's choice:** Manual merge
**Notes:** Final gate before publish workflows trigger

---

## manifest.json Version Sync

### Sync mechanism

| Option | Description | Selected |
|--------|-------------|----------|
| Vite build-time injection | Vite reads version from package.json, writes into output manifest.json. | ✓ |
| npm version lifecycle script | postversion script patches manifest.json at changeset bump time. | |
| GitHub Actions step | CI patches manifest.json before zipping. | |

**User's choice:** Vite build-time injection
**Notes:** User added that development builds should also have versioning — git commit hash or similar. Decided on `{version}-dev+{commithash}` format.

### Development build version format

| Option | Description | Selected |
|--------|-------------|----------|
| version-dev+commithash | e.g. 2.1.0-dev+a3b4c5d. Semver-compliant. | ✓ |
| 0.0.0-dev+commithash | Obvious dev build but loses base version context. | |
| version.timestamp | Sortable but not semver-compliant. | |

**User's choice:** version-dev+commithash
**Notes:** CWS strips suffix at publish time

---

## Tag Format Transition

### Tag format

| Option | Description | Selected |
|--------|-------------|----------|
| Clean break | Per-package tags only. Old v* tags stay in history. | ✓ |
| Dual tags temporarily | Both v* and per-package tags during transition. | |
| Keep v* for host only | Host keeps v* tags, extension gets per-package. | |

**User's choice:** Clean break
**Notes:** installer-release.yml switches to workflow_dispatch in Phase 8

---

## Claude's Discretion

- Exact `.changeset/config.json` structure and options
- `src/native-host/package.json` stub structure
- CI workflow YAML for changesets action
- Commit message format for changesets

## Deferred Ideas

None — discussion stayed within phase scope
