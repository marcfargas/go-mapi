---
status: partial
phase: 06-changesets-monorepo-scaffold
source: [06-VERIFICATION.md]
started: 2026-04-12T17:45:00Z
updated: 2026-04-12T17:45:00Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. Extension changeset triggers correct Version Packages PR
expected: Push a changeset file under `src/extension` to main. CI creates a "Version Packages" PR that bumps only `src/extension/package.json` and generates a git tag `go-mapi-extension@X.Y.Z` on merge.
result: [pending]

### 2. Host changeset triggers correct Version Packages PR
expected: Push a changeset file under `src/native-host` to main. CI creates a "Version Packages" PR that bumps only `src/native-host/package.json` and generates a git tag `go-mapi-host@X.Y.Z` on merge.
result: [pending]

### 3. Go host binary reports version 2.1.0
expected: Run `npm run build:native-host`, execute the binary or observe READY message — HostVersion should report `2.1.0` (from `src/native-host/package.json`).
result: [pending]

### 4. Extension build embeds 2.1.0 in manifest.json
expected: Run `npm run build:extension`, inspect `src/extension/dist/manifest.json` — `version` field should be `2.1.0` (from `src/extension/package.json`).
result: [pending]

### 5. CHANGESET_TOKEN secret exists in repo
expected: Navigate to https://github.com/marcfargas/go-mapi/settings/secrets/actions — `CHANGESET_TOKEN` secret is present.
result: [pending]

## Summary

total: 5
passed: 0
issues: 0
pending: 5
skipped: 0
blocked: 0

## Gaps
