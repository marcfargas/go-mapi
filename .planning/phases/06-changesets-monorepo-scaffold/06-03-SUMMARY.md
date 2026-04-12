---
phase: 06-changesets-monorepo-scaffold
plan: 03
subsystem: ci
tags: [changesets, github-actions, version-packages, ci, release-pipeline]
status: awaiting-human-action
dependency_graph:
  requires: [06-01]
  provides: [version-packages-workflow]
  affects: [07-extension-publish, 08-host-release]
tech_stack:
  added: []
  patterns: [changesets/action, fine-grained-pat, concurrency-groups]
key_files:
  created:
    - .github/workflows/version-packages.yml
  modified: []
decisions:
  - "Use CHANGESET_TOKEN PAT (not GITHUB_TOKEN) for both checkout and PR creation — required for downstream CI to trigger on Version Packages PR branch (GitHub design limitation)"
  - "No publish input in Phase 6 — scaffold only; Phases 7/8 add publish step that triggers tag creation"
  - "changesets/action@v1.7.0 pinned by version tag (not SHA) — acceptable risk for solo OSS project per T-06-06"
  - "fetch-depth: 0 required for changesets to compare full git history across all accumulated changesets"
metrics:
  duration: ~5min
  completed_date: "2026-04-12"
  tasks_total: 2
  tasks_completed: 1
  files_created: 1
  files_modified: 0
requirements: [CS-04, CS-05, CS-06]
---

# Phase 06 Plan 03: Version Packages Workflow Summary

**One-liner:** GitHub Actions workflow for changesets Version Packages PR automation, using fine-grained PAT to bypass GITHUB_TOKEN CI trigger limitation.

## Status: Awaiting Human Action (Task 2)

Plan paused at checkpoint:human-action — CHANGESET_TOKEN PAT must be created by Marc via GitHub web UI before the workflow can run.

## Completed Tasks

| Task | Description | Commit | Files |
|------|-------------|--------|-------|
| 1 | Create version-packages.yml workflow | d802e31 | `.github/workflows/version-packages.yml` |

## Pending Tasks

| Task | Type | Description |
|------|------|-------------|
| 2 | human-action | Create CHANGESET_TOKEN Fine-Grained PAT in GitHub Settings + add as repo secret |

## What Was Built

`.github/workflows/version-packages.yml` — a GitHub Actions workflow that:

- Triggers on `push` to `main` branch
- Uses `actions/checkout@v4` with `CHANGESET_TOKEN` PAT (not `GITHUB_TOKEN`) — critical for downstream CI to fire on the Version Packages PR branch
- Runs `npm ci` to install workspace dependencies
- Runs `changesets/action@v1.7.0` with no `publish` input (scaffold only)
- Creates a "Version Packages" PR when changeset files are present on main
- Uses `concurrency` group to prevent duplicate runs on rapid pushes
- Has `permissions: contents: write, pull-requests: write`

## Key Design Decisions

**Why CHANGESET_TOKEN instead of GITHUB_TOKEN?**

GitHub prevents `GITHUB_TOKEN` commits from triggering other CI workflows — this is a documented security design to prevent infinite loops. If we used `GITHUB_TOKEN`, the Version Packages PR branch would not trigger build/test workflows, defeating the purpose of the PR gate. The fine-grained PAT bypasses this restriction. This is also why the PAT must be passed to BOTH `actions/checkout` (for the branch push) AND `env.GITHUB_TOKEN` (for the PR creation).

**Why no `publish` input?**

The `publish` step in changesets/action would attempt to run npm publish. Phase 6 only scaffolds the versioning infrastructure. Phases 7 and 8 will add the publish steps for extension (CWS + Edge Add-ons) and host (GitHub Releases + installer artifacts) respectively.

**How CS-04 (per-package git tags) is satisfied:**

Tag format `go-mapi-extension@X.Y.Z` and `go-mapi-host@X.Y.Z` is already configured in `.changeset/config.json` via `privatePackages.tag: true` (completed in Plan 01). The actual tag creation happens when the Version Packages PR is merged and the action runs its publish step. Phases 7/8 add the `publish` input that triggers tag creation.

## Human Action Required (Task 2)

Marc must create the CHANGESET_TOKEN Fine-Grained PAT:

1. Go to https://github.com/settings/personal-access-tokens/new
2. Token name: `go-mapi-changeset-token`
3. Expiration: 90 days (or custom)
4. Repository access: Only select repositories -> `go-mapi`
5. Permissions: Contents (Read and write), Pull requests (Read and write)
6. Generate token and copy it
7. Go to https://github.com/marcfargas/go-mapi/settings/secrets/actions/new
8. Name: `CHANGESET_TOKEN`
9. Secret: paste the generated token
10. Add secret

Verification: CHANGESET_TOKEN must appear at https://github.com/marcfargas/go-mapi/settings/secrets/actions

## Deviations from Plan

None — plan executed exactly as written for Task 1.

## Threat Surface

Workflow introduces a CI path that uses a fine-grained PAT with write access:

| Flag | File | Description |
|------|------|-------------|
| threat_flag: elevated-token | .github/workflows/version-packages.yml | CHANGESET_TOKEN PAT has Contents+PRs write access; scoped to go-mapi repo only (T-06-05 mitigated) |

## Self-Check

- [x] `.github/workflows/version-packages.yml` exists and contains required elements
- [x] Commit d802e31 exists in git history
- [x] Verification grep PASS: changesets/action@v1.7.0, CHANGESET_TOKEN, fetch-depth: 0, no publish:
