---
quick_id: 260423-olq
description: Wails build wrapper reads .env.local and injects OAuth via ldflags
status: complete
date: 2026-04-23
commit: (pending docs commit)
---

# Quick Task 260423-olq — Summary

## Goal

Fix the Wails local-build pipeline so `npm run build` produces a `.exe`
that doesn't fatal at startup with:

> FATAL: OAuth client_id missing — build was not wired correctly (expected
> -ldflags -X main.oauthClientID, or GOMAPI_OAUTH_CLIENT_ID env var for
> wails dev)

## What shipped

### Behavior change

`npm run build` now reads `.env.local` at the repo root (already gitignored,
pre-existing from Phase 8 dev workflow) and injects the two OAuth values as
linker `-X` directives:

```
wails build -platform windows/amd64 \
    -ldflags "-X \"main.oauthClientID=...\" -X \"main.oauthClientSecret=...\""
```

Previously `npm run build` produced a binary with empty package-level
`oauthClientID` / `oauthClientSecret`, which tripped the guard in
`src/app/credentials_check.go`. rc.2 (Marc's previously-installed build)
was credentialed because it came from a different pipeline (Phase 11
release CI) that already did ldflags injection; `npm run build` has
never worked for a locally-installable binary until now.

### Code changes

| File | Change |
|------|--------|
| `scripts/build-wails.ps1` (NEW, 100 LOC) | PS 5.1 wrapper; reads .env.local, builds ldflags, runs wails build. Sets CC/CXX to triple-prefixed mstorsjo clang when available (ARM64-host compat). |
| `package.json` | `build` script now invokes the wrapper instead of inline cmd.exe gymnastics. CC/CXX env-var juggling removed from the script (now handled inside the wrapper). |

### Secret hygiene

- `.env.local` stays gitignored; the wrapper reads it but never writes or
  echoes its contents.
- The wrapper prints `ldflags: (oauth vars set -- values redacted)` —
  it does NOT print the values.
- **KNOWN LEAK:** Wails's own CLI banner prints `LDFlags | <full string>`
  to stdout, which means the client_secret appears in build logs. Per the
  previously-recorded project decision ("Desktop OAuth secrets ship with
  binaries — for go-mapi's PKCE Desktop client, a build-log leak is not
  session-takeover class; flag and continue, don't halt") this is
  accepted as-is. Follow-up improvement tracked: pipe Wails stdout through
  a filter that redacts the LDFlags line.

## Verification

- `npm run build` succeeds end-to-end: interceptor DLLs (x64+x86) plus
  a credentialed `src/app/build/bin/go-mapi.exe` (6.1s Wails build).
- `npm run build:installer` produces `src/installer/go-mapi-setup.exe`
  at 7.10 MB, bundling the credentialed .exe plus both DLLs plus the
  diagnostics scripts.
- Wails's Build Options banner confirms `LDFlags` populated (see known-leak
  note above).

## Deferred

- Redaction of Wails CLI stdout leak (small PS filter). Non-blocking.
- No new unit tests — the wrapper is shell glue over an existing build
  chain. The build either succeeds (producing a credentialed binary) or
  fails loudly at startup (pre-existing guard in credentials_check.go).

## Scope discipline

- Did NOT touch `src/app/credentials_check.go` or the dev env-var fallback.
- Did NOT touch Phase 11 release CI (it already did this correctly).
- Did NOT add a new secrets store or rotate anything.
