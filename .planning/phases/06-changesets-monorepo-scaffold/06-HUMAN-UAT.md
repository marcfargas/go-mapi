---
status: resolved
phase: 06-changesets-monorepo-scaffold
source: [06-VERIFICATION.md]
started: 2026-04-12T17:45:00Z
updated: 2026-04-12T19:00:00Z
---

## Current Test

[all resolved]

## Tests

### 1. Extension changeset triggers correct Version Packages PR
expected: Push a changeset file under `src/extension` to main. CI creates a "Version Packages" PR that bumps only `src/extension/package.json` and generates a git tag `go-mapi-extension@X.Y.Z` on merge.
result: deferred — end-to-end test required pushing to `origin/main`, but `origin/main` is ahead of `develop` by 5 commits (v2.0.1 hotfix merged but never back-merged to develop). Test will be exercised naturally when the first real changeset lands on main after the v2.0.1 reconciliation. Workflow file syntax and `privatePackages.tag: true` behavior verified structurally in VERIFICATION.md.

### 2. Host changeset triggers correct Version Packages PR
expected: Push a changeset file under `src/native-host` to main. CI creates a "Version Packages" PR that bumps only `src/native-host/package.json` and generates a git tag `go-mapi-host@X.Y.Z` on merge.
result: deferred — same reason as test 1.

### 3. Go host binary reports version 2.1.0
expected: Run `npm run build:native-host`, execute the binary or observe READY message — HostVersion should report `2.1.0` (from `src/native-host/package.json`).
result: passed — READY message output: `{"type":"ready","version":"2.1.0","hostVersion":"2.1.0"}`

### 4. Extension build embeds 2.1.0 in manifest.json
expected: Run `npm run build:extension`, inspect `src/extension/dist/manifest.json` — `version` field should be `2.1.0` (from `src/extension/package.json`).
result: passed — `jq -r '.version' src/extension/dist/manifest.json` returned `2.1.0`

### 5. CHANGESET_TOKEN secret exists in repo
expected: Navigate to https://github.com/marcfargas/go-mapi/settings/secrets/actions — `CHANGESET_TOKEN` secret is present.
result: passed — `gh secret list --repo marcfargas/go-mapi` confirms `CHANGESET_TOKEN` added 2026-04-12T18:41:52Z

## Summary

total: 5
passed: 3
issues: 0
pending: 0
skipped: 0
blocked: 0
deferred: 2

## Gaps

### Gap: v2.0.1 hotfix not back-merged to develop
status: open
discovered: 2026-04-12
detail: During UAT for Phase 6, discovered that `origin/main` contains 5 commits from a v2.0.1 hotfix PR (#3, #4) that were never merged back into `develop`. This blocks end-to-end testing of tests 1 & 2, and will cause merge conflicts when v2.1.0 ships.
resolution: Reconcile `origin/main` into `develop` as a separate task before v2.1.0 ships. Not in Phase 6 scope.
